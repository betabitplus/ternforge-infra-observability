terraform {
  backend "remote" {
    hostname     = "betabitplus-ternforge.scalr.io"
    organization = "env-v0pbe6o21etjctniq"

    workspaces {
      name = "ternforge-fleet-health"
    }
  }
}
