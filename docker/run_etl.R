#!/usr/bin/env Rscript

log <- function(...) cat(sprintf("[%s] ", Sys.time()), ..., "\n", file = stderr())

log("Starting cyberarxiv ETL runner")

if (!requireNamespace("cyberarxiv", quietly = TRUE)) {
  stop("Package 'cyberarxiv' is not installed in the image. Make sure the Dockerfile installed it.")
}

max_results <- as.integer(Sys.getenv("MAX_RESULTS", "100"))
only_new    <- identical(Sys.getenv("ONLY_NEW", "false"), "true")

sources_env <- Sys.getenv("CYBERARXIV_SOURCES", "")
sources <- if (nzchar(sources_env)) trimws(strsplit(sources_env, ",", fixed = TRUE)[[1]]) else NULL

db_path <- Sys.getenv("CYBERARXIV_DB_PATH", "/srv/cyberarxiv/data/cyberarxiv.duckdb")
dir.create(dirname(db_path), showWarnings = FALSE, recursive = TRUE)

log("Parameters:",
    "max_results=", max_results,
    ", only_new=", only_new,
    ", sources=", if (is.null(sources)) "<all>" else paste(sources, collapse = ","))

tryCatch({
  result <- cyberarxiv::etl(
    max_results = max_results,
    only_new    = only_new,
    db_path     = db_path,
    sources     = sources
  )

  log("ETL run completed successfully:",
      "inserted=", result$inserted,
      ", updated=", result$updated,
      ", skipped=", result$skipped)
}, error = function(e) {
  log("ETL run failed:", conditionMessage(e))
  traceback()
  quit(status = 1)
})
