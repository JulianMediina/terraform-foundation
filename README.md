# terraform-foundation

Infraestructura fundacional de la plataforma DaviPlata: lo que tiene que existir *antes* de que cualquier otro repo pueda desplegar algo. Corre una sola vez por cuenta AWS (o muy esporádicamente, cuando cambia la plataforma).

## Qué crea `bootstrap/`

- Un bucket S3 de estado remoto + una tabla DynamoDB de lock **por ambiente** (`integracion`, `laboratorio`, `produccion`), cada uno cifrado con su propia llave KMS.
- Una llave KMS adicional por ambiente para cifrar el bucket del sitio estático (separada de la del estado).
- El proveedor OIDC de GitHub Actions (una sola vez) y un rol IAM (`gha-<ambiente>`) por ambiente, least-privilege, consumiendo el módulo [`iam-github-oidc`](https://github.com/JulianMediina/terraform-modules/tree/main/modules/iam-github-oidc) de `terraform-modules`.
- Una alarma de presupuesto mensual (AWS Budgets) con notificación al 80% (real) y 100% (proyectado).

## Por qué estado local

Este es el único repo con estado de Terraform **local**: si `bootstrap` guardara su propio estado en el backend remoto que él mismo crea, existiría una dependencia circular (necesitas el bucket para guardar el estado que crea el bucket). Tras cada `apply`, el archivo `terraform.tfstate` resultante debe resguardarse fuera del repo — no se commitea (ver `.gitignore`).

## Dependencia con `terraform-modules`

`bootstrap` consume el módulo `iam-github-oidc` por una referencia de `source` **literal** (`?ref=v0.1.0`, ver comentario en `main.tf`) — no puede depender de una variable, porque Terraform resuelve `source`/`version` en `init`, antes de leer ninguna variable. Por eso `terraform-modules` debe tener al menos el tag `v0.1.0` publicado **antes** de aplicar `bootstrap`, y si cambia la versión hay que actualizar el literal a mano.

## Cómo ejecutarlo

```
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # completar con tus valores
terraform init
terraform plan
terraform apply
```

Requiere credenciales AWS con permisos administrativos temporales (ver `docs/runbook.md` en `daviplata-app` para la guía paso a paso de cómo obtenerlas). Una vez aplicado, esas credenciales ya no se necesitan para el día a día: el resto de los pipelines usa los roles OIDC creados aquí.

## Frecuencia y gobierno

Trunk-based development: cambios vía PR hacia `main`, revisados con cuidado — un error aquí afecta a toda la plataforma. `foundation-ci.yml` valida formato, sintaxis y seguridad (tfsec/checkov) en cada PR; no hay `apply` automático.

