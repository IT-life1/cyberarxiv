#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

log "Running cyberarxiv ETL pipeline"
if ! Rscript /srv/cyberarxiv/docker/run_etl.R; then
  log "ERROR: ETL pipeline failed. Exiting."
  exit 1
fi

log "ETL pipeline completed successfully"
log "Starting dashboard server"
exec Rscript /srv/cyberarxiv/docker/run_dashboard.R