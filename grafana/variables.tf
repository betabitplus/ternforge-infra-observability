variable "grafana_stack_slug" {
  type = string
}

variable "github_app_id" {
  type = string
}

variable "github_app_installation_id" {
  type = string
}

variable "github_data_source_secret" {
  type      = string
  sensitive = true
}

variable "alert_email" {
  type      = string
  sensitive = true
}

variable "metric_series_allowance" {
  type    = number
  default = 10000
}
