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
  metric_alerts = {
    coverage_mismatch = {
      name      = "Ternforge fleet coverage mismatch"
      expr      = "abs(last_over_time(ternforge_fleet_expected_repositories[48h]) - last_over_time(ternforge_fleet_observed_repositories[48h]))"
      threshold = 0.5
      summary   = "Expected and observed managed repository counts differ."
    }
    token_scope_mismatch = {
      name      = "Ternforge Renovate token scope mismatch"
      expr      = "1 - last_over_time(ternforge_fleet_token_scope_ok[48h])"
      threshold = 0.5
      summary   = "The Renovate installation token repository set does not match the managed fleet."
    }
    grafana_capacity = {
      name           = "Ternforge Grafana metric capacity warning"
      expr           = "100 * (grafanacloud_instance_active_series or on() vector(0)) / ${var.metric_series_allowance}"
      threshold      = 80
      datasource_uid = "grafanacloud-usage"
      summary        = "Grafana Cloud active series reached 80 percent of the reviewed metric-series allowance."
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
    for_each = local.metric_alerts
    content {
      uid            = "ternforge-${replace(rule.key, "_", "-")}"
      name           = rule.value.name
      condition      = "B"
      for            = "0s"
      no_data_state  = "OK"
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
        datasource_uid = try(rule.value.datasource_uid, "grafanacloud-prom")

        relative_time_range {
          from = 600
          to   = 0
        }

        model = jsonencode({
          datasource = {
            type = "prometheus"
            uid  = try(rule.value.datasource_uid, "grafanacloud-prom")
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

  rule {
    uid            = "ternforge-update-run-failed"
    name           = "Ternforge update delivery health"
    condition      = "D"
    for            = "0s"
    no_data_state  = "Alerting"
    exec_err_state = "KeepLast"
    is_paused      = false

    annotations = {
      summary = "An update-delivery health signal is critical; inspect the signal label."
    }

    labels = {
      service = "ternforge"
      scope   = "platform-health"
    }

    data {
      ref_id         = "A"
      datasource_uid = grafana_data_source.github.uid

      relative_time_range {
        from = 1209600
        to   = 0
      }

      model = jsonencode({
        datasource = {
          type = "grafana-github-datasource"
          uid  = grafana_data_source.github.uid
        }
        owner      = "betabitplus"
        repository = "ternforge-infra-updates"
        queryType  = "Workflow_Runs"
        options = {
          workflow = "reconcile.yml"
          branch   = "main"
        }
        refId = "A"
      })
    }

    data {
      ref_id         = "B"
      datasource_uid = grafana_data_source.github.uid

      relative_time_range {
        from = 315360000
        to   = 0
      }

      model = jsonencode({
        datasource = {
          type = "grafana-github-datasource"
          uid  = grafana_data_source.github.uid
        }
        owner      = "betabitplus"
        repository = ""
        queryType  = "Issues"
        options = {
          query     = "is:open label:renovate/config-error"
          timeField = 0
        }
        refId = "B"
      })
    }

    data {
      ref_id         = "C"
      datasource_uid = "__expr__"

      relative_time_range {
        from = 1209600
        to   = 0
      }

      model = jsonencode({
        datasource = {
          type = "__expr__"
          uid  = "__expr__"
        }
        expression    = <<-SQL
          WITH latest_release AS (
            SELECT conclusion, run_started_at, updated_at
            FROM A
            WHERE event = 'repository_dispatch' AND status = 'completed'
            ORDER BY created_at DESC
            LIMIT 1
          ), release_state AS (
            SELECT
              COALESCE(MAX(CASE WHEN conclusion <> 'success' THEN 1 ELSE 0 END), 0) AS failed,
              COALESCE(MAX(CASE WHEN TIMESTAMPDIFF(SECOND, run_started_at, updated_at) > 600 THEN 1 ELSE 0 END), 0) AS slow,
              COALESCE(MAX(CASE WHEN TIMESTAMPDIFF(SECOND, run_started_at, updated_at) > 2700 THEN 1 ELSE 0 END), 0) AS token_boundary
            FROM latest_release
          ), freshness AS (
            SELECT CASE WHEN COALESCE(
              UNIX_TIMESTAMP() - MAX(CASE WHEN status = 'completed' AND conclusion = 'success' THEN UNIX_TIMESTAMP(updated_at) ELSE NULL END),
              999999
            ) > 129600 THEN 1 ELSE 0 END AS stale
            FROM A
          ), warnings AS (
            SELECT CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END AS warning
            FROM B
          )
          SELECT 'release-run-failed' AS signal, failed AS value FROM release_state
          UNION ALL SELECT 'recovery-stale', stale FROM freshness
          UNION ALL SELECT 'processing-over-10m', slow FROM release_state
          UNION ALL SELECT 'token-boundary', token_boundary FROM release_state
          UNION ALL SELECT 'renovate-config-warning', warning FROM warnings
        SQL
        format        = "alerting"
        intervalMs    = 1000
        maxDataPoints = 43200
        refId         = "C"
        type          = "sql"
      })
    }

    data {
      ref_id         = "D"
      datasource_uid = "-100"

      relative_time_range {
        from = 0
        to   = 0
      }

      model = jsonencode({
        conditions = [{
          evaluator = {
            params = [0.5]
            type   = "gt"
          }
          operator = { type = "and" }
          query    = { params = ["D"] }
          reducer  = { params = [], type = "last" }
          type     = "query"
        }]
        datasource = {
          type = "__expr__"
          uid  = "-100"
        }
        expression    = "C"
        intervalMs    = 1000
        maxDataPoints = 43200
        refId         = "D"
        type          = "threshold"
      })
    }

    notification_settings {
      contact_point = grafana_contact_point.fleet_health.name
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
