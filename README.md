# terraform-foundation

Infraestructura fundacional de la plataforma DaviPlata: lo que tiene que existir *antes* de que cualquier otro repo pueda desplegar algo. Cambia con poca frecuencia, pero se gestiona con el mismo principio GitOps que el resto de la plataforma — **nada de `terraform apply` manual desde una laptop**.

## Qué crea `bootstrap/`

- Un bucket S3 de estado remoto + una tabla DynamoDB de lock **por ambiente** (`integracion`, `laboratorio`, `produccion`), cada uno cifrado con su propia llave KMS.
- Una llave KMS adicional por ambiente para cifrar el repositorio ECR de imágenes de la aplicación (separada de la del estado; el nombre del recurso Terraform sigue siendo `aws_kms_key.site` por herencia del diseño original en S3+CloudFront, pero su uso real hoy es el repositorio ECR).
- El proveedor OIDC de GitHub Actions (una sola vez) y un rol IAM por ambiente (`gha-integracion`, `gha-laboratorio`, `gha-produccion`, y `gha-foundation` para este mismo repo), least-privilege, consumiendo el módulo [`iam-github-oidc`](https://github.com/JulianMediina/terraform-modules/tree/main/modules/iam-github-oidc) de `terraform-modules`.
- Una alarma de presupuesto mensual (AWS Budgets) con notificación al 80% (real) y 100% (proyectado).

## Backend remoto propio (y por qué no es circular)

`bootstrap` guarda su estado en `s3://daviplata-tfstate-foundation`, un bucket **separado** de los `tfstate-<ambiente>` que este mismo código crea para el resto de la plataforma. Ese bucket y su tabla de lock no los gestiona Terraform — sería el mismo problema circular de siempre, aplicado a sí mismo. Los crea, de forma idempotente, `scripts/ensure-backend.sh` (S3 API + DynamoDB API directas) **antes** de cada `terraform init`, tanto en `foundation-plan.yml` como en `foundation-apply.yml`.

## Sin credenciales estáticas — ni siquiera aquí

Solo el arranque original de toda la plataforma (el primer `apply` que creó el proveedor OIDC) necesitó una credencial estática, porque en ese momento no existía ningún rol al que asumir por OIDC. Una vez que el proveedor existe, ese problema no se repite: `foundation-plan.yml`/`foundation-apply.yml` asumen el rol `gha-foundation` por OIDC igual que `terraform-live`/`daviplata-app` asumen `gha-<ambiente>` — este repo se aplica cambios a sí mismo sin depender de ningún secret de larga duración. El usuario IAM que respaldaba la credencial original (`FOUNDATION_AWS_ACCESS_KEY_ID`/`SECRET`) quedó sin uso y su access key se desactivó.

## GitOps: plan en PR, apply al merge

- **`foundation-plan.yml`**: en cada PR que toque `bootstrap/**` — asegura el backend, `terraform fmt`/`validate`, tfsec/checkov, `terraform plan` comentado en el PR.
- **`foundation-apply.yml`**: al hacer merge a `main` — aplica automáticamente, protegido por el GitHub Environment `foundation` (aprobación requerida).

## Dependencia con `terraform-modules`

`bootstrap` consume el módulo `iam-github-oidc` por una referencia de `source` **literal** (`?ref=vX.Y.Z`, ver comentarios en `main.tf` — los distintos módulos `gha_role_*` no tienen por qué apuntar todos al mismo tag) — no puede depender de una variable, porque Terraform resuelve `source`/`version` en `init`, antes de leer ninguna variable. Por eso `terraform-modules` debe tener el tag correspondiente publicado **antes** de aplicar `bootstrap`, y si cambia la versión hay que actualizar el literal a mano.

## Frecuencia y gobierno

Trunk-based development: cambios vía PR hacia `main`, revisados con cuidado — un error aquí afecta a toda la plataforma.
