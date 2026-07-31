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

# --- Estado remoto de Terraform: un bucket + una tabla de lock por ambiente ---

resource "aws_kms_key" "tfstate" {
  for_each = toset(var.environments)

  description         = "Cifrado del estado de Terraform - ambiente ${each.key}"
  enable_key_rotation = true

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

  tags = merge(var.tags, { Environment = each.key })
}

# --- KMS para los buckets de sitio (uno por ambiente, distinto del de tfstate) ---

resource "aws_kms_key" "site" {
  for_each = toset(var.environments)

  description         = "Cifrado del bucket de sitio estático - ambiente ${each.key}"
  enable_key_rotation = true

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
    sid    = "ObservabilityManage"
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:PutDashboard",
      "cloudwatch:GetDashboard",
      "cloudwatch:DeleteDashboards",
      "sns:CreateTopic",
      "sns:DeleteTopic",
      "sns:GetTopicAttributes",
      "sns:SetTopicAttributes",
      "sns:Subscribe",
      "sns:Unsubscribe",
      "sns:ListSubscriptionsByTopic",
      "sns:TagResource",
    ]
    resources = ["*"]
  }
}

module "gha_role" {
  source   = "git::https://github.com/${var.github_org}/terraform-modules.git//modules/iam-github-oidc?ref=${var.modules_repo_ref}"
  for_each = toset(var.environments)

  environment                = each.key
  create_oidc_provider       = each.key == local.first_environment
  existing_oidc_provider_arn = each.key == local.first_environment ? null : module.gha_role[local.first_environment].oidc_provider_arn

  allowed_subjects = [
    "repo:${var.github_org}/terraform-live:environment:${each.key}",
    "repo:${var.github_org}/daviplata-app:environment:${each.key}",
  ]

  policy_json = data.aws_iam_policy_document.least_privilege[each.key].json
  tags        = merge(var.tags, { Environment = each.key })
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
