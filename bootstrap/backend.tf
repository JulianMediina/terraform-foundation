# Backend remoto propio de terraform-foundation, separado de los buckets
# tfstate-<ambiente> que este mismo código crea para el resto de la
# plataforma. El bucket y la tabla de lock no los gestiona este Terraform
# (ver scripts/ensure-backend.sh) — sería el mismo problema circular que
# resolvimos para terraform-live, pero aplicado a sí mismo. Los workflows
# corren ensure-backend.sh antes de "terraform init" en cada plan/apply.
terraform {
  backend "s3" {
    bucket         = "daviplata-tfstate-foundation"
    key            = "foundation/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "daviplata-tflock-foundation"
    encrypt        = true
  }
}
