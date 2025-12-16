#' Save arXiv publications to RDS
#' @param data A data.frame to save
#' @param filename Name of the RDS file (default: "arxiv_papers.rds")
#' @param dir Directory to save the file (default: "raw-data")
#'
#' @return Invisibly returns a list with path, number of rows, and file size
#' @export
#'
#' @examples
#' \dontrun{
#' papers <- get_arxiv_papers(max_results = 50)
#' save_raw_data(papers)
#' save_raw_data(papers, filename = "my_papers.rds")
#' }
save_raw_data <- function(data, filename = "arxiv_papers.rds", dir = "raw-data") {
  if (!is.data.frame(data)) {
    stop("'data' must be a data.frame")
  }
  
  if (!dir.exists(dir)) {
    dir.create(dir, recursive = TRUE)
  }
  
  filepath <- file.path(dir, filename)
  
  saveRDS(data, file = filepath)
  
  invisible(list(
    path = filepath,
    rows = nrow(data),
    size_bytes = file.size(filepath)
  ))
}

#' Load publications from local RDS storage
#' @param filename Name of the RDS file to load (default: "arxiv_papers.rds")
#' @param dir Directory containing the file (default: "raw-data")
#'
#' @return A data.frame loaded from the RDS file, or an empty data.frame if file not found
#' @export
#'
#' @examples
#' \dontrun{
#' papers <- load_raw_data()
#' papers <- load_raw_data(filename = "my_papers.rds")
#' }
load_raw_data <- function(filename = "arxiv_papers.rds", dir = "raw-data") {
  filepath <- file.path(dir, filename)
  
  if (!file.exists(filepath)) {
    warning("File '", filepath, "' not found. Returning empty data.frame.")
    return(data.frame())
  }
  
  readRDS(filepath)
}