#!/usr/bin/env bash
# Crea (si no existen) el bucket S3 y la tabla DynamoDB donde vive el propio
# estado de terraform-foundation. Deliberadamente NO se gestionan con
# Terraform: son la infraestructura de la infraestructura, y Terraform no
# puede guardar su estado en un backend que él mismo todavía no ha creado.
# Idempotente: seguro de correr en cada plan/apply.
set -euo pipefail

BUCKET="daviplata-tfstate-foundation"
TABLE="daviplata-tflock-foundation"
REGION="us-east-1"

if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
  echo "==> Bucket ${BUCKET} ya existe"
else
  echo "==> Creando bucket ${BUCKET}"
  aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}"
  aws s3api put-bucket-versioning --bucket "${BUCKET}" --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "${BUCKET}" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket "${BUCKET}" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi

if aws dynamodb describe-table --table-name "${TABLE}" --region "${REGION}" >/dev/null 2>&1; then
  echo "==> Tabla ${TABLE} ya existe"
else
  echo "==> Creando tabla ${TABLE}"
  aws dynamodb create-table --table-name "${TABLE}" --region "${REGION}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST
  aws dynamodb wait table-exists --table-name "${TABLE}" --region "${REGION}"
fi

echo "==> Backend de terraform-foundation listo"
