#!/usr/bin/env Rscript
options(repos = 'https://cloud.r-project.org')

log <- function(...) cat(sprintf("[%s] ", Sys.time()), ..., "\n", file = stderr())

log("Starting cyberarxiv ETL runner")

if (!requireNamespace("cyberarxiv", quietly = TRUE)) {
  stop("Package 'cyberarxiv' is not installed in the image. Make sure the Dockerfile installed it.")
}

max_results <- as.integer(Sys.getenv("MAX_RESULTS", "100"))
query_env <- Sys.getenv("QUERY", "")
query <- if (nzchar(query_env)) query_env else NULL

log("Parameters:", "query=", if (is.null(query)) "<NULL>" else query, ", max_results=", max_results)

# Устанавливаем рабочий каталог для сохранения данных
raw_data_dir <- "/srv/cyberarxiv/raw-data"
dir.create(raw_data_dir, showWarnings = FALSE, recursive = TRUE)

tryCatch({
  log("Fetching papers from arXiv...")
  papers <- cyberarxiv::get_arxiv_papers(query = query, max_results = max_results)
  log("Fetched", if (is.data.frame(papers)) nrow(papers) else length(papers), "records")

  log("Saving raw data...")
  cyberarxiv::save_raw_data(papers, dir = raw_data_dir)
  log("Raw data saved to", raw_data_dir)

  log("Loading raw data for classification...")
  raw_data <- cyberarxiv::load_raw_data(dir = raw_data_dir)
  log("Loaded", nrow(raw_data), "records from raw storage")

  log("Classifying data...")
  classified <- cyberarxiv::classify_data(raw_data)
  log("Classification finished, classified", nrow(classified), "records")

  log("Saving publications to DB...")
  db_path <- Sys.getenv("CYBERARXIV_DB_PATH", "/srv/cyberarxiv/data/cyberarxiv.duckdb")
  dir.create(dirname(db_path), showWarnings = FALSE, recursive = TRUE)
  stats <- cyberarxiv::save_publications(classified, db_path = db_path)
  log("Publications saved:", 
      "inserted=", stats$inserted, 
      ", updated=", stats$updated, 
      ", skipped=", stats$skipped)

  log("ETL run completed successfully")
}, error = function(e) {
  log("ETL run failed:", conditionMessage(e))
  traceback()
  quit(status = 1)
})
