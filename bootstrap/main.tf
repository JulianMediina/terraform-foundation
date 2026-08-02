terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

locals {
  first_environment = var.environments[0]
}

# Política explícita de las llaves KMS: delega la administración en las
# políticas IAM de la cuenta (comportamiento por defecto de AWS), pero de
# forma explícita para que quede auditable como código.
data "aws_iam_policy_document" "kms_default" {
  statement {
    sid    = "EnableAccountRootAccess"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }
}

# --- Estado remoto de Terraform: un bucket + una tabla de lock por ambiente ---

resource "aws_kms_key" "tfstate" {
  for_each = toset(var.environments)

  description         = "Cifrado del estado de Terraform - ambiente ${each.key}"
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.kms_default.json

  tags = merge(var.tags, { Environment = each.key })
}

resource "aws_kms_alias" "tfstate" {
  for_each = toset(var.environments)

  name          = "alias/${var.project}-tfstate-${each.key}"
  target_key_id = aws_kms_key.tfstate[each.key].key_id
}

#tfsec:ignore:aws-s3-enable-bucket-logging -- el acceso a nivel de API ya queda registrado por CloudTrail (habilitado a nivel de cuenta); un log bucket adicional no se justifica para el alcance de esta prueba.
resource "aws_s3_bucket" "tfstate" {
  for_each = toset(var.environments)

  bucket = "${var.project}-tfstate-${each.key}"

  tags = merge(var.tags, { Environment = each.key })
}

data "aws_iam_policy_document" "tfstate_https_only" {
  for_each = toset(var.environments)

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    actions = [
      "s3:*"
    ]
    resources = [
      aws_s3_bucket.tfstate[each.key].arn,
      "${aws_s3_bucket.tfstate[each.key].arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate_https_only" {
  for_each = toset(var.environments)

  bucket = aws_s3_bucket.tfstate[each.key].id
  policy = data.aws_iam_policy_document.tfstate_https_only[each.key].json
}

resource "aws_s3_bucket_versioning" "tfstate" {
  for_each = toset(var.environments)

  bucket = aws_s3_bucket.tfstate[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  for_each = toset(var.environments)

  bucket = aws_s3_bucket.tfstate[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tfstate[each.key].arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  for_each = toset(var.environments)

  bucket = aws_s3_bucket.tfstate[each.key].id

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  for_each = toset(var.environments)

  bucket = aws_s3_bucket.tfstate[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#tfsec:ignore:aws-dynamodb-table-customer-key -- la tabla solo guarda el LockID de Terraform (nada sensible); una CMK dedicada añade costo sin beneficio real. Ya usa cifrado con la llave administrada de AWS.
resource "aws_dynamodb_table" "tflock" {
  for_each = toset(var.environments)

  name         = "${var.project}-tflock-${each.key}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(var.tags, { Environment = each.key })
}

# --- KMS para el repositorio ECR del sitio (uno por ambiente, distinto del de tfstate) ---

# A diferencia de CloudFront (un servicio, sin identidad IAM propia), el rol
# que hace pull de la imagen (ecs-express) es un principal IAM normal: le
# alcanza con un permiso kms:Decrypt en su propia policy (ver módulo
# ecs-express), sin necesitar un statement de servicio en la política de la
# llave. La política por defecto (delega en IAM vía el root de la cuenta) es
# suficiente aquí.
resource "aws_kms_key" "site" {
  for_each = toset(var.environments)

  description         = "Cifrado del repositorio ECR del sitio - ambiente ${each.key}"
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.kms_default.json

  tags = merge(var.tags, { Environment = each.key })

  # Mismo caso que aws_sns_topic.foundation_pipeline: cuando este apply es el
  # mismo que le otorga a gha-foundation un permiso nuevo (p.ej.
  # kms:UpdateKeyDescription) Y lo usa (p.ej. renombrar la descripción), la
  # sesión ya asumida no ve el permiso nuevo hasta que IAM propaga el cambio
  # de policy -sin esta espera, falla intermitentemente con AccessDenied.
  depends_on = [time_sleep.foundation_role_propagation]
}

resource "aws_kms_alias" "site" {
  for_each = toset(var.environments)

  name          = "alias/${var.project}-site-${each.key}"
  target_key_id = aws_kms_key.site[each.key].key_id
}

# --- Rol OIDC de GitHub Actions por ambiente ---
# El módulo vive en terraform-modules; foundation lo consume igual que cualquier
# otro consumidor, para no duplicar la lógica de creación del rol y su trust policy.

data "aws_iam_policy_document" "least_privilege" {
  for_each = toset(var.environments)

  statement {
    sid    = "TerraformBackendState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.tfstate[each.key].arn,
      "${aws_s3_bucket.tfstate[each.key].arn}/*",
    ]
  }

  statement {
    sid       = "TerraformBackendLock"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = [aws_dynamodb_table.tflock[each.key].arn]
  }

  statement {
    sid    = "SiteKmsUse"
    effect = "Allow"
    # kms:CreateGrant/RevokeGrant: ECR los usa internamente para delegarse a
    # sí mismo el cifrado/descifrado de las capas de imagen con una llave
    # administrada por el cliente -sin esto, ecr:CreateRepository falla con
    # un AccessDenied de KMS aunque el rol ya tenga permiso directo sobre la
    # llave (kms:CreateGrant no se hereda de Encrypt/Decrypt/GenerateDataKey).
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
      "kms:CreateGrant",
      "kms:RevokeGrant",
    ]
    resources = [aws_kms_key.site[each.key].arn, aws_kms_key.tfstate[each.key].arn]
  }

  # kms:ListAliases no admite restricción por ARN de recurso (lista todos los
  # alias de la cuenta/región; no hay una variante "por alias"). terraform-live
  # la necesita para resolver la llave del repositorio ECR por nombre de alias
  # en tiempo de plan/apply (data "aws_kms_alias").
  statement {
    sid       = "KmsListAliases"
    effect    = "Allow"
    actions   = ["kms:ListAliases"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrRepositoryManage"
    effect = "Allow"
    actions = [
      "ecr:CreateRepository",
      "ecr:DescribeRepositories",
      "ecr:DeleteRepository",
      "ecr:PutLifecyclePolicy",
      "ecr:GetLifecyclePolicy",
      "ecr:DeleteLifecyclePolicy",
      "ecr:PutImageScanningConfiguration",
      "ecr:PutImageTagMutability",
      "ecr:TagResource",
      "ecr:UntagResource",
      "ecr:ListTagsForResource",
    ]
    resources = ["arn:aws:ecr:*:${data.aws_caller_identity.current.account_id}:repository/${var.project}-${each.key}-*"]
  }

  # El push/pull real de imágenes (release.yml de daviplata-app, mismo rol
  # gha-<ambiente>) necesita estas acciones además de las de gestión.
  # ecr:GetAuthorizationToken es la única que no admite restricción por ARN
  # de recurso (autentica contra el registro completo de la cuenta).
  statement {
    sid    = "EcrImagePushPull"
    effect = "Allow"
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]
    resources = ["arn:aws:ecr:*:${data.aws_caller_identity.current.account_id}:repository/${var.project}-${each.key}-*"]
  }

  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcsClusterManage"
    effect = "Allow"
    actions = [
      "ecs:CreateCluster",
      "ecs:DescribeClusters",
      "ecs:DeleteCluster",
      "ecs:PutClusterCapacityProviders",
      "ecs:TagResource",
      "ecs:UntagResource",
      "ecs:ListTagsForResource",
      "ecs:UpdateClusterSettings",
    ]
    resources = ["arn:aws:ecs:*:${data.aws_caller_identity.current.account_id}:cluster/${var.project}-${each.key}"]
  }

  # Cubre tanto la gestión del servicio Express (Terraform) como la
  # actualización de la imagen desplegada fuera de Terraform (deploy.yml de
  # daviplata-app, mismo rol). ecs:RegisterTaskDefinition se acota por
  # familia -Express Mode genera revisiones versionadas cuyo ARN completo no
  # se conoce de antemano.
  statement {
    sid    = "EcsExpressServiceManage"
    effect = "Allow"
    actions = [
      "ecs:CreateExpressGatewayService",
      "ecs:UpdateExpressGatewayService",
      "ecs:DescribeExpressGatewayService",
      "ecs:DeleteExpressGatewayService",
      "ecs:DescribeServices",
      "ecs:ListServiceDeployments",
      "ecs:DescribeServiceDeployments",
      "ecs:TagResource",
      "ecs:UntagResource",
      "ecs:ListTagsForResource",
    ]
    resources = ["arn:aws:ecs:*:${data.aws_caller_identity.current.account_id}:service/${var.project}-${each.key}/*"]
  }

  statement {
    sid       = "EcsTaskDefinitionManage"
    effect    = "Allow"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
    resources = ["arn:aws:ecs:*:${data.aws_caller_identity.current.account_id}:task-definition/${var.project}-${each.key}-*"]
  }

  # El módulo ecs-express crea dos roles por ambiente (ejecución de tareas e
  # infraestructura de ECS). PassRole está separado y acotado a esos mismos
  # ARNs -es la única forma de que ECS pueda asumirlos sin abrir PassRole a
  # cualquier rol de la cuenta.
  statement {
    sid    = "EcsExpressIamRoleManage"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:GetRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/ecs-express-${each.key}-*"]
  }

  statement {
    sid       = "EcsExpressIamPassRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/ecs-express-${each.key}-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com", "ecs.amazonaws.com"]
    }
  }

  statement {
    sid    = "CloudWatchManage"
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:TagResource",
      "cloudwatch:UntagResource",
      "cloudwatch:ListTagsForResource",
    ]
    resources = ["arn:aws:cloudwatch:*:${data.aws_caller_identity.current.account_id}:alarm:${var.project}-${each.key}-*"]
  }

  statement {
    sid    = "CloudWatchDashboardManage"
    effect = "Allow"
    actions = [
      "cloudwatch:PutDashboard",
      "cloudwatch:GetDashboard",
      "cloudwatch:DeleteDashboards",
    ]
    resources = ["arn:aws:cloudwatch::${data.aws_caller_identity.current.account_id}:dashboard/${var.project}-${each.key}"]
  }

  statement {
    sid    = "SnsManage"
    effect = "Allow"
    actions = [
      "sns:CreateTopic",
      "sns:DeleteTopic",
      "sns:GetTopicAttributes",
      "sns:SetTopicAttributes",
      "sns:Subscribe",
      "sns:Unsubscribe",
      "sns:ListSubscriptionsByTopic",
      "sns:GetSubscriptionAttributes",
      "sns:SetSubscriptionAttributes",
      "sns:TagResource",
      "sns:UntagResource",
      "sns:ListTagsForResource",
      "sns:Publish",
    ]
    resources = ["arn:aws:sns:*:${data.aws_caller_identity.current.account_id}:${var.project}-${each.key}-*"]
  }
}

# Política del rol que usa este mismo repo (terraform-foundation) para
# aplicarse a sí mismo por OIDC. Cubre exactamente los recursos que bootstrap
# gestiona: los 3 buckets/tablas/llaves de tfstate, el proveedor OIDC, los
# roles gha-<ambiente> (y este mismo, gha-foundation) y el budget mensual.
# Las acciones de solo-lectura se validaron con un "terraform plan" real
# contra un permission set de AWS SSO con este mismo alcance antes de crear
# el rol -no son una lista adivinada.
data "aws_iam_policy_document" "foundation_least_privilege" {
  statement {
    sid    = "TfstateBackendManage"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:PutBucketVersioning",
      "s3:GetBucketVersioning",
      "s3:PutEncryptionConfiguration",
      "s3:GetEncryptionConfiguration",
      "s3:PutBucketPublicAccessBlock",
      "s3:GetBucketPublicAccessBlock",
      "s3:PutLifecycleConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:PutBucketPolicy",
      "s3:GetBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketTagging",
      "s3:GetBucketTagging",
      "s3:GetBucketAcl",
      "s3:GetBucketCors",
      "s3:GetBucketLogging",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetBucketReplication",
      "s3:GetBucketRequestPayment",
      "s3:GetBucketWebsite",
      "s3:GetAccelerateConfiguration",
      "s3:GetBucketNotification",
      "s3:GetReplicationConfiguration",
      "s3:GetIntelligentTieringConfiguration",
      "s3:GetBucketOwnershipControls",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "arn:aws:s3:::${var.project}-tfstate-*",
      "arn:aws:s3:::${var.project}-tfstate-*/*",
    ]
  }

  statement {
    sid    = "DynamoDbLockTablesManage"
    effect = "Allow"
    actions = [
      "dynamodb:CreateTable",
      "dynamodb:DescribeTable",
      "dynamodb:UpdateTable",
      "dynamodb:DeleteTable",
      "dynamodb:TagResource",
      "dynamodb:UntagResource",
      "dynamodb:ListTagsOfResource",
      "dynamodb:PutItem",
      "dynamodb:GetItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeContinuousBackups",
      "dynamodb:UpdateContinuousBackups",
      "dynamodb:DescribeTimeToLive",
    ]
    resources = ["arn:aws:dynamodb:*:*:table/${var.project}-tflock-*"]
  }

  # Las llaves KMS de estado/sitio se crean en tiempo de apply, así que no hay
  # ARN existente que referenciar en el momento de escribir esta policy.
  statement {
    sid    = "KmsManage"
    effect = "Allow"
    actions = [
      "kms:CreateKey",
      "kms:DescribeKey",
      "kms:UpdateKeyDescription",
      "kms:GetKeyPolicy",
      "kms:PutKeyPolicy",
      "kms:EnableKeyRotation",
      "kms:GetKeyRotationStatus",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:ListResourceTags",
      "kms:CreateAlias",
      "kms:UpdateAlias",
      "kms:DeleteAlias",
      "kms:ListAliases",
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "OidcProviderManage"
    effect = "Allow"
    actions = [
      "iam:CreateOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviders",
    ]
    resources = ["*"]
  }

  # Cubre tanto los roles gha-<ambiente> de terraform-live/daviplata-app como
  # este mismo rol (gha-foundation) — el pipeline puede actualizar su propia
  # policy/trust si bootstrap cambia.
  statement {
    sid    = "GhaRoleManage"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:GetRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = ["arn:aws:iam::*:role/gha-*"]
  }

  statement {
    sid    = "BudgetsManage"
    effect = "Allow"
    actions = [
      "budgets:ViewBudget",
      "budgets:ModifyBudget",
      "budgets:ListTagsForResource",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "PipelineSnsManage"
    effect = "Allow"
    actions = [
      "sns:CreateTopic",
      "sns:DeleteTopic",
      "sns:GetTopicAttributes",
      "sns:SetTopicAttributes",
      "sns:Subscribe",
      "sns:Unsubscribe",
      "sns:ListSubscriptionsByTopic",
      "sns:GetSubscriptionAttributes",
      "sns:SetSubscriptionAttributes",
      "sns:TagResource",
      "sns:UntagResource",
      "sns:ListTagsForResource",
      "sns:Publish",
    ]
    resources = ["arn:aws:sns:*:${data.aws_caller_identity.current.account_id}:${var.project}-foundation-*"]
  }
}

# source y ref son literales a propósito: Terraform los resuelve en "init",
# antes de leer las variables, así que no pueden depender de var.github_org
# ni var.modules_repo_ref. Si cambia el usuario/org de GitHub o se publica
# una versión nueva del módulo, este valor se actualiza a mano aquí.
#
# Se separa en dos bloques (uno solo para el primer ambiente, otro con
# for_each para el resto) en vez de un único for_each que se referencie a sí
# mismo por índice: eso último produce un ciclo real en el grafo de Terraform
# (el nodo "close" del for_each termina dependiendo de sus propias instancias).
module "gha_role_provider" {
  source = "git::https://github.com/JulianMediina/terraform-modules.git//modules/iam-github-oidc?ref=v0.1.2"

  environment          = local.first_environment
  create_oidc_provider = true

  # El claim "sub" real que emite GitHub incluye el ID inmutable de cuenta y
  # de repositorio junto al nombre (repo:<org>@<orgId>/<repo>@<repoId>:...),
  # no solo "repo:<org>/<repo>:..." como documentan los ejemplos genéricos.
  # Se confirmó decodificando el token en un job real (ver commit de fix).
  # Los "*" cubren el ID sin tener que hardcodearlo por repo.
  allowed_subjects = [
    "repo:${var.github_org}@*/terraform-live@*:environment:${local.first_environment}",
    "repo:${var.github_org}@*/daviplata-app@*:environment:${local.first_environment}",
  ]

  policy_json = data.aws_iam_policy_document.least_privilege[local.first_environment].json
  tags        = merge(var.tags, { Environment = local.first_environment })
}

module "gha_role_rest" {
  source   = "git::https://github.com/JulianMediina/terraform-modules.git//modules/iam-github-oidc?ref=v0.1.2"
  for_each = toset(slice(var.environments, 1, length(var.environments)))

  environment                = each.key
  create_oidc_provider       = false
  existing_oidc_provider_arn = module.gha_role_provider.oidc_provider_arn

  allowed_subjects = [
    "repo:${var.github_org}@*/terraform-live@*:environment:${each.key}",
    "repo:${var.github_org}@*/daviplata-app@*:environment:${each.key}",
  ]

  policy_json = data.aws_iam_policy_document.least_privilege[each.key].json
  tags        = merge(var.tags, { Environment = each.key })
}

# Rol que usa este mismo repo (terraform-foundation) para aplicarse a sí
# mismo por OIDC, cerrando la única excepción de credencial estática que
# quedaba en toda la plataforma. Se crea con la credencial estática existente
# la última vez que se usa; después de este apply, foundation-plan.yml y
# foundation-apply.yml se cambian para asumir este rol en vez de usar
# FOUNDATION_AWS_ACCESS_KEY_ID/SECRET.
module "gha_role_foundation" {
  source = "git::https://github.com/JulianMediina/terraform-modules.git//modules/iam-github-oidc?ref=v0.1.4"

  environment                = "foundation"
  create_oidc_provider       = false
  existing_oidc_provider_arn = module.gha_role_provider.oidc_provider_arn

  allowed_subjects = [
    "repo:${var.github_org}@*/terraform-foundation@*:environment:foundation",
  ]

  policy_json = data.aws_iam_policy_document.foundation_least_privilege.json
  tags        = merge(var.tags, { Environment = "foundation" })
}

locals {
  gha_role_arns = merge(
    { (local.first_environment) = module.gha_role_provider.role_arn },
    { for env, mod in module.gha_role_rest : env => mod.role_arn }
  )
}

# --- Alarma de presupuesto ---

resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-monthly-budget"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_notification_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.budget_notification_emails
  }
}

# --- Notificación de resultado del pipeline (plan/apply de este repo) ---
# Reutiliza el mismo correo del presupuesto -es la misma persona a la que le
# interesa saber qué pasa con la fundación de la plataforma.

# El propio pipeline se acaba de otorgar sns:CreateTopic a sí mismo (en este
# mismo apply, vía module.gha_role_foundation) — IAM tarda unos segundos en
# propagar un cambio de policy a una sesión ya asumida. Sin esta espera, el
# create del tópico compite contra la propagación y falla intermitentemente.
resource "time_sleep" "foundation_role_propagation" {
  depends_on      = [module.gha_role_foundation]
  create_duration = "15s"
}

#tfsec:ignore:aws-sns-topic-encryption-use-cmk -- solo transporta notificaciones de texto del pipeline, no datos sensibles; cifrado ya con la llave administrada de AWS (alias/aws/sns).
resource "aws_sns_topic" "foundation_pipeline" {
  depends_on = [time_sleep.foundation_role_propagation]

  name              = "${var.project}-foundation-pipeline"
  kms_master_key_id = "alias/aws/sns"
  tags              = var.tags
}

resource "aws_sns_topic_subscription" "foundation_pipeline_email" {
  for_each = toset(var.budget_notification_emails)

  topic_arn = aws_sns_topic.foundation_pipeline.arn
  protocol  = "email"
  endpoint  = each.value
}
