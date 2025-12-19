#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

log "Running cyberarxiv ETL pipeline"
Rscript /srv/cyberarxiv/docker/run_etl.R

log "Starting dashboard server"
exec Rscript /srv/cyberarxiv/docker/run_dashboard.R
