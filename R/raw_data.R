#' Save raw publications to Parquet
#' @param data A data.frame to save (as returned by \code{collect_all()})
#' @param filename Name of the Parquet file (default: "arxiv_papers.parquet")
#' @param dir Directory to save the file (default: "raw-data")
#'
#' @return Invisibly returns a list with path, number of rows, and file size
#' @export
#'
#' @examples
#' \dontrun{
#' papers <- collect_all(max_results = 50)
#' save_raw_data(papers)
#' save_raw_data(papers, filename = "my_papers.parquet")
#' }
save_raw_data <- function(data, filename = "arxiv_papers.parquet", dir = "raw-data") {
  if (!is.data.frame(data)) {
    stop("'data' must be a data.frame")
  }

  if (!dir.exists(dir)) {
    dir.create(dir, recursive = TRUE)
  }

  filepath <- file.path(dir, filename)

  arrow::write_parquet(data, filepath)

  invisible(list(
    path     = filepath,
    rows     = nrow(data),
    size_bytes = file.size(filepath)
  ))
}

#' Load raw publications from local Parquet storage
#' @param filename Name of the Parquet file to load (default: "arxiv_papers.parquet")
#' @param dir Directory containing the file (default: "raw-data")
#'
#' @return A data.frame loaded from the Parquet file, or a typed empty data.frame if not found
#' @export
#'
#' @examples
#' \dontrun{
#' papers <- load_raw_data()
#' papers <- load_raw_data(filename = "my_papers.parquet")
#' }
load_raw_data <- function(filename = "arxiv_papers.parquet", dir = "raw-data") {
  filepath <- file.path(dir, filename)

  if (!file.exists(filepath)) {
    # Backward compat: fall back to legacy RDS if parquet not yet written
    rds_path <- sub("\\.parquet$", ".rds", filepath)
    if (file.exists(rds_path)) {
      warning("Parquet file not found; loading legacy RDS '", rds_path,
              "'. Run save_raw_data() to migrate.")
      return(readRDS(rds_path))
    }

    warning("File '", filepath, "' not found. Returning empty data.frame.")
    return(data.frame(
      id             = character(0),
      source         = character(0),
      language       = character(0),
      link           = character(0),
      title          = character(0),
      authors        = character(0),
      abstract       = character(0),
      categories     = character(0),
      published_date = character(0),
      updated_date   = character(0),
      stringsAsFactors = FALSE
    ))
  }

  as.data.frame(arrow::read_parquet(filepath))
}
