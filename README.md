# ternforge-infra-observability

Platform-level health observability for the Ternforge fleet.

This repository owns only the observability presentation and alerting plane:

- Grafana Cloud/OpenTofu configuration and its separate state-only Scalr workspace;
- the `Ternforge Platform Health` dashboard;
- the read-only GitHub data source;
- actionable platform-health alerts and their contact point.

It does **not** own repository desired state, CI/release execution, Renovate policy,
update reconciliation, or a second fleet registry. Those remain owned by
`ternforge-infra-repository-control`, `ternforge-infra-ci`, and
`ternforge-infra-updates` respectively.

## Quota boundary

Observability is intentionally ingestion-light:

- no Collector, Loki, Tempo, custom service, database, or per-repository metric export;
- no new custom OTLP series for general CI/release/control visibility;
- `ternforge-infra-updates` continues to emit only its existing bounded update
  reconciliation metrics, without repository/branch/SHA/run-ID labels;
- CI, release, repository-control, maintenance, and Actions usage/cost views use
  the cached Grafana GitHub data source instead of metric ingestion;
- repository/workflow drill-down is selected on demand rather than continuously
  polling every workflow in every repository;
- the dashboard refreshes every five minutes and alert rules evaluate every five
  minutes;
- fleet/token coverage reads the latest trigger-independent full-fleet state;
- active series, 24h average DPM, and included DPM per series remain visible on the dashboard.

The GitHub App selected-repository membership is managed from the same authoritative
fleet inventory as the rest of Ternforge, so observability does not maintain a
second repository list.

The existing Grafana folder/dashboard UID and Scalr workspace name keep their
historical `ternforge-fleet-health` identity during this ownership split. They are
stable external/state identifiers, not current repository ownership labels; renaming
them would create migration work without changing the supported contract.

## Apply

Run the manual **platform health grafana** workflow from `main`. It uses the
protected `observability` environment, a short-lived GitHub OIDC exchange to the
existing Grafana state-only Scalr workspace with `terraform-version=auto`, a reviewable plan/apply boundary,
GitHub data-source health readback, and a final no-drift plan.
