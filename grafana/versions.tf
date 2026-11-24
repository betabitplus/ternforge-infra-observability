terraform {
  required_version = "= 1.13.10"

  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "4.45.1"
    }
  }
}
