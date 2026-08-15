provider "grafana" {
  alias = "cloud"
}

provider "grafana" {
  alias      = "stack"
  url        = "https://${var.grafana_stack_slug}.grafana.net"
  retries    = 3
  retry_wait = 5
}

locals {
  alerts = {
    update_run_failed = {
      name      = "Ternforge central update workflow failed"
      expr      = "1 - last_over_time(ternforge_update_run_success{ternforge_trigger=\"release\"}[14d])"
      threshold = 0.5
      summary   = "The latest release-triggered full-fleet reconciliation failed."
    }
    recovery_stale = {
      name      = "Ternforge full-fleet recovery is stale"
      expr      = "time() - last_over_time(ternforge_update_last_success_unixtime[48h])"
      threshold = 129600
      no_data   = "Alerting"
      summary   = "No successful full-fleet reconciliation has been observed within 36 hours."
    }
    coverage_mismatch = {
      name      = "Ternforge fleet coverage mismatch"
      expr      = "abs(last_over_time(ternforge_fleet_expected_repositories{ternforge_trigger=\"release\"}[14d]) - last_over_time(ternforge_fleet_observed_repositories{ternforge_trigger=\"release\"}[14d]))"
      threshold = 0.5
      summary   = "Expected and observed managed repository counts differ."
    }
    token_scope_mismatch = {
      name      = "Ternforge Renovate token scope mismatch"
      expr      = "1 - last_over_time(ternforge_fleet_token_scope_ok{ternforge_trigger=\"release\"}[14d])"
      threshold = 0.5
      summary   = "The Renovate installation token repository set does not match the managed fleet."
    }
    processing_slow = {
      name      = "Ternforge release processing exceeds ten minutes"
      expr      = "last_over_time(ternforge_update_processing_duration_seconds{ternforge_trigger=\"release\"}[14d])"
      threshold = 600
      summary   = "A completed release-triggered reconciliation exceeded the reviewed ten-minute latency threshold."
    }
    token_boundary = {
      name      = "Ternforge execution approaches token boundary"
      expr      = "last_over_time(ternforge_update_processing_duration_seconds{ternforge_trigger=\"release\"}[14d])"
      threshold = 2700
      summary   = "A reconciliation reached 45 minutes and is approaching the one-hour installation-token lifetime."
    }
    renovate_configuration_warning = {
      name      = "Ternforge Renovate configuration warning"
      expr      = "last_over_time(ternforge_renovate_configuration_warnings[36h])"
      threshold = 0.5
      summary   = "At least one managed repository has an open Renovate configuration-warning issue."
    }
    grafana_capacity = {
      name      = "Ternforge Grafana metric capacity warning"
      expr      = "100 * grafanacloud_instance_active_otlp_series / ${var.metric_series_allowance}"
      threshold = 80
      summary   = "Grafana Cloud active OTLP series reached 80 percent of the reviewed metric-series allowance."
    }
  }
}

resource "grafana_cloud_plugin_installation" "github" {
  provider = grafana.cloud

  stack_slug = var.grafana_stack_slug
  slug       = "grafana-github-datasource"

  lifecycle {
    ignore_changes = [version]
  }
}

resource "grafana_folder" "fleet_health" {
  provider = grafana.stack

  uid   = "ternforge-fleet-health"
  title = "Ternforge Platform Health"
}

resource "grafana_data_source" "github" {
  provider = grafana.stack

  type        = "grafana-github-datasource"
  name        = "Ternforge GitHub"
  uid         = "ternforge-github"
  access_mode = "proxy"

  json_data_encoded = jsonencode({
    selectedAuthType = "github-app"
    appId            = var.github_app_id
    installationId   = var.github_app_installation_id
    cachingEnabled   = true
  })

  secure_json_data_encoded = var.github_data_source_secret

  depends_on = [grafana_cloud_plugin_installation.github]
}

resource "grafana_dashboard" "fleet_health" {
  provider = grafana.stack

  folder      = grafana_folder.fleet_health.uid
  overwrite   = true
  message     = "Ternforge Platform Health managed by OpenTofu"
  config_json = file("${path.module}/../observability/platform-health-dashboard.json")
}

resource "grafana_contact_point" "fleet_health" {
  provider = grafana.stack

  name = "Ternforge Fleet Health"

  email {
    addresses               = [var.alert_email]
    single_email            = true
    disable_resolve_message = false
    subject                 = "{{ template \"default.title\" . }}"
    message                 = "{{ template \"default.message\" . }}"
  }
}

resource "grafana_rule_group" "fleet_health" {
  provider = grafana.stack

  name             = "ternforge-fleet-health"
  folder_uid       = grafana_folder.fleet_health.uid
  interval_seconds = 300

  dynamic "rule" {
    for_each = local.alerts
    content {
      uid            = "ternforge-${replace(rule.key, "_", "-")}"
      name           = rule.value.name
      condition      = "B"
      for            = "0s"
      no_data_state  = try(rule.value.no_data, "OK")
      exec_err_state = "KeepLast"
      is_paused      = false

      annotations = {
        summary = rule.value.summary
      }

      labels = {
        service = "ternforge"
        scope   = "platform-health"
      }

      data {
        ref_id         = "A"
        datasource_uid = "grafanacloud-prom"

        relative_time_range {
          from = 600
          to   = 0
        }

        model = jsonencode({
          datasource = {
            type = "prometheus"
            uid  = "grafanacloud-prom"
          }
          editorMode    = "code"
          expr          = rule.value.expr
          instant       = true
          intervalMs    = 1000
          maxDataPoints = 43200
          range         = false
          refId         = "A"
        })
      }

      data {
        ref_id         = "B"
        datasource_uid = "-100"

        relative_time_range {
          from = 0
          to   = 0
        }

        model = jsonencode({
          conditions = [{
            evaluator = {
              params = [rule.value.threshold]
              type   = "gt"
            }
            operator = { type = "and" }
            query    = { params = ["B"] }
            reducer  = { params = [], type = "last" }
            type     = "query"
          }]
          datasource = {
            type = "__expr__"
            uid  = "-100"
          }
          expression    = "A"
          intervalMs    = 1000
          maxDataPoints = 43200
          refId         = "B"
          type          = "threshold"
        })
      }

      notification_settings {
        contact_point = grafana_contact_point.fleet_health.name
      }
    }
  }
}

output "platform_health" {
  value = {
    plugin_slug    = grafana_cloud_plugin_installation.github.slug
    stack_url      = "https://${var.grafana_stack_slug}.grafana.net"
    folder_uid     = grafana_folder.fleet_health.uid
    datasource_uid = grafana_data_source.github.uid
    dashboard_uid  = grafana_dashboard.fleet_health.uid
    alert_group    = grafana_rule_group.fleet_health.name
    contact_point  = grafana_contact_point.fleet_health.name
  }
}
