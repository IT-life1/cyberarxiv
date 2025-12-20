#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >&2
}

log "Running cyberarxiv ETL pipeline"
if ! Rscript /srv/cyberarxiv/docker/run_etl.R 2>&1; then
  log "ERROR: ETL pipeline failed. Exiting."
  exit 1
fi

log "ETL pipeline completed successfully"
log "Starting dashboard server"
exec Rscript /srv/cyberarxiv/docker/run_dashboard.R 2>&1
