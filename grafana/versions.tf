terraform {
  required_version = "= 1.12.5"

  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "4.45.1"
    }
  }
}
