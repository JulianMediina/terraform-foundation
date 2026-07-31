terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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

resource "aws_dynamodb_table" "tflock" {
  for_each = toset(var.environments)

  name         = "${var.project}-tflock-${each.key}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(var.tags, { Environment = each.key })
}

# --- KMS para los buckets de sitio (uno por ambiente, distinto del de tfstate) ---

resource "aws_kms_key" "site" {
  for_each = toset(var.environments)

  description         = "Cifrado del bucket de sitio estático - ambiente ${each.key}"
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.kms_default.json

  tags = merge(var.tags, { Environment = each.key })
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
    sid    = "SiteBucketManage"
    effect = "Allow"
    actions = [
      "s3:*",
    ]
    resources = [
      "arn:aws:s3:::${var.project}-${each.key}-*",
      "arn:aws:s3:::${var.project}-${each.key}-*/*",
    ]
  }

  statement {
    sid       = "SiteKmsUse"
    effect    = "Allow"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [aws_kms_key.site[each.key].arn, aws_kms_key.tfstate[each.key].arn]
  }

  # kms:ListAliases no admite restricción por ARN de recurso (lista todos los
  # alias de la cuenta/región; no hay una variante "por alias"). terraform-live
  # la necesita para resolver la llave de sitio por nombre de alias en tiempo
  # de plan/apply (data "aws_kms_alias").
  statement {
    sid       = "KmsListAliases"
    effect    = "Allow"
    actions   = ["kms:ListAliases"]
    resources = ["*"]
  }

  # Las acciones de gestión de CloudFront no admiten restricción por ARN de
  # recurso en IAM (limitación documentada del servicio); se acotan por acción.
  statement {
    sid    = "CloudFrontManage"
    effect = "Allow"
    actions = [
      "cloudfront:CreateDistribution",
      "cloudfront:GetDistribution",
      "cloudfront:UpdateDistribution",
      "cloudfront:DeleteDistribution",
      "cloudfront:TagResource",
      "cloudfront:ListTagsForResource",
      "cloudfront:CreateOriginAccessControl",
      "cloudfront:GetOriginAccessControl",
      "cloudfront:UpdateOriginAccessControl",
      "cloudfront:DeleteOriginAccessControl",
      "cloudfront:CreateResponseHeadersPolicy",
      "cloudfront:GetResponseHeadersPolicy",
      "cloudfront:UpdateResponseHeadersPolicy",
      "cloudfront:DeleteResponseHeadersPolicy",
      "cloudfront:CreateInvalidation",
      "cloudfront:GetInvalidation",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "CloudWatchManage"
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:DescribeAlarms",
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
      "sns:TagResource",
    ]
    resources = ["arn:aws:sns:*:${data.aws_caller_identity.current.account_id}:${var.project}-${each.key}-*"]
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
