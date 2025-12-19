#!/usr/bin/env Rscript
options(repos = 'https://cloud.r-project.org')

log <- function(...) cat(sprintf("[%s] ", Sys.time()), ..., "\n")

log("Starting cyberarxiv ETL runner")

if (!requireNamespace("cyberarxiv", quietly = TRUE)) {
  stop("Package 'cyberarxiv' is not installed in the image. Make sure the Dockerfile installed it.")
}

max_results <- as.integer(Sys.getenv("MAX_RESULTS", "100"))
query_env <- Sys.getenv("QUERY", "")
query <- if (nzchar(query_env)) query_env else NULL

log("Parameters:", "query=", if (is.null(query)) "<NULL>" else query, ", max_results=", max_results)

tryCatch({
  log("Fetching papers from arXiv...")
  papers <- cyberarxiv::get_arxiv_papers(query = query, max_results = max_results)
  log("Fetched", if (is.data.frame(papers)) nrow(papers) else length(papers), "records")

  log("Saving raw data...")
  cyberarxiv::save_raw_data(papers)
  log("Raw data saved")

  log("Classifying data...")
  classified <- cyberarxiv::classify_data(papers)
  log("Classification finished")

  log("Saving publications to DB...")
  cyberarxiv::save_publications(classified)
  log("Publications saved")

  log("ETL run completed successfully")
}, error = function(e) {
  log("ETL run failed:", conditionMessage(e))
  quit(status = 1)
})
