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

# Try ML classification if service is available.
# Reads papers from DuckDB (where ETL just wrote them) and writes ML
# tags into ml_results.default. Errors here are non-fatal — users can
# always re-run classification from the Shiny "ML Classifier" tab.
log "Checking ML classification service..."
if Rscript -e '
  url <- Sys.getenv("ML_SERVICE_URL", "http://cyberarxiv-ml:5001")
  tryCatch({
    resp <- httr2::request(url) |>
      httr2::req_url_path("health") |>
      httr2::req_timeout(seconds = 5) |>
      httr2::req_perform()
    if (httr2::resp_status(resp) != 200) {
      cat("ML service not healthy, skipping\n"); quit(status = 0)
    }
    cat("ML service is healthy, running classification...\n")
    data <- cyberarxiv::load_publications()
    if (is.null(data) || nrow(data) == 0) {
      cat("DuckDB has no papers yet, skipping ML classification\n")
      quit(status = 0)
    }
    # classify_with_ml expects an `id` column; load_publications returns `paper_id`.
    data$id <- data$paper_id
    ml_results <- cyberarxiv::classify_with_ml(data, ml_service_url = url)
    stats <- cyberarxiv::update_ml_tags(ml_results, task_id = "default")
    cat("ML classification updated", stats$updated, "records\n")
  }, error = function(e) {
    cat("ML classification skipped:", conditionMessage(e), "\n")
  })
' 2>&1; then
log "ML classification step completed"
else
  log "ML classification step skipped or failed (non-fatal)"
fi

log "Starting Shiny GUI on port 3838"
exec Rscript /srv/cyberarxiv/docker/run_shiny.R 2>&1
