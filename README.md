# terraform-foundation

Infraestructura fundacional de la plataforma DaviPlata: lo que tiene que existir *antes* de que cualquier otro repo pueda desplegar algo. Cambia con poca frecuencia, pero se gestiona con el mismo principio GitOps que el resto de la plataforma — **nada de `terraform apply` manual desde una laptop**.

## Qué crea `bootstrap/`

- Un bucket S3 de estado remoto + una tabla DynamoDB de lock **por ambiente** (`integracion`, `laboratorio`, `produccion`), cada uno cifrado con su propia llave KMS.
- Una llave KMS adicional por ambiente para cifrar el bucket del sitio estático (separada de la del estado).
- El proveedor OIDC de GitHub Actions (una sola vez) y un rol IAM (`gha-<ambiente>`) por ambiente, least-privilege, consumiendo el módulo [`iam-github-oidc`](https://github.com/JulianMediina/terraform-modules/tree/main/modules/iam-github-oidc) de `terraform-modules`.
- Una alarma de presupuesto mensual (AWS Budgets) con notificación al 80% (real) y 100% (proyectado).

## Backend remoto propio (y por qué no es circular)

`bootstrap` guarda su estado en `s3://daviplata-tfstate-foundation`, un bucket **separado** de los `tfstate-<ambiente>` que este mismo código crea para el resto de la plataforma. Ese bucket y su tabla de lock no los gestiona Terraform — sería el mismo problema circular de siempre, aplicado a sí mismo. Los crea, de forma idempotente, `scripts/ensure-backend.sh` (S3 API + DynamoDB API directas) **antes** de cada `terraform init`, tanto en `foundation-plan.yml` como en `foundation-apply.yml`.

## La única credencial estática de toda la plataforma

`foundation-plan.yml`/`foundation-apply.yml` no pueden autenticarse por OIDC: son el pipeline que **crea** el proveedor OIDC del que dependen todos los demás roles (`gha-integracion`, `gha-laboratorio`, `gha-produccion`). Por eso, y solo aquí, se usa un usuario IAM con credenciales de larga duración guardadas como secrets del repositorio (`FOUNDATION_AWS_ACCESS_KEY_ID` / `FOUNDATION_AWS_SECRET_ACCESS_KEY`). Es una excepción deliberada y documentada, no un descuido — el resto de la plataforma (`terraform-live`, `daviplata-app`) no tiene ninguna credencial estática.

## GitOps: plan en PR, apply al merge

- **`foundation-plan.yml`**: en cada PR que toque `bootstrap/**` — asegura el backend, `terraform fmt`/`validate`, tfsec/checkov, `terraform plan` comentado en el PR.
- **`foundation-apply.yml`**: al hacer merge a `main` — aplica automáticamente, protegido por el GitHub Environment `foundation` (aprobación requerida).

## Dependencia con `terraform-modules`

`bootstrap` consume el módulo `iam-github-oidc` por una referencia de `source` **literal** (`?ref=v0.1.2`, ver comentario en `main.tf`) — no puede depender de una variable, porque Terraform resuelve `source`/`version` en `init`, antes de leer ninguna variable. Por eso `terraform-modules` debe tener ese tag publicado **antes** de aplicar `bootstrap`, y si cambia la versión hay que actualizar el literal a mano.

## Frecuencia y gobierno

Trunk-based development: cambios vía PR hacia `main`, revisados con cuidado — un error aquí afecta a toda la plataforma.
