variable "environments" {
  description = "Ambientes de la plataforma, en orden de promoción."
  type        = list(string)
  default     = ["integracion", "laboratorio", "produccion"]
}

variable "project" {
  description = "Nombre corto del proyecto, usado como prefijo de recursos."
  type        = string
  default     = "daviplata"
}

variable "github_org" {
  description = "Organización o usuario de GitHub dueño de los repositorios."
  type        = string
}

variable "budget_limit_usd" {
  description = "Límite mensual de presupuesto de la cuenta, en USD."
  type        = number
  default     = 25
}

variable "budget_notification_emails" {
  description = "Correos que reciben la alerta de presupuesto."
  type        = list(string)
}

variable "tags" {
  description = "Tags comunes aplicados a todos los recursos fundacionales."
  type        = map(string)
  default = {
    Project   = "daviplata"
    ManagedBy = "terraform-foundation"
    Owner     = "platform-team"
  }
}
