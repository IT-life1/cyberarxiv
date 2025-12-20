#' Get path to DuckDB database file
#'
#' @noRd
.cyberarxiv_db_path <- function() {
  p <- Sys.getenv("CYBERARXIV_DB_PATH", unset = NA_character_)
  if (!is.na(p) && nzchar(p)) return(p)

  p <- getOption("cyberarxiv.db_path", default = NA_character_)
  if (!is.na(p) && nzchar(p)) return(p)

  file.path("inst", "extdata", "cyberarxiv.duckdb")
}

#' Connect to DuckDB and ensure schema exists
#' @noRd
.cyberarxiv_connect <- function(db_path = .cyberarxiv_db_path()) {
  if (!requireNamespace("DBI", quietly = TRUE)) stop("Package 'DBI' is required.")
  if (!requireNamespace("duckdb", quietly = TRUE)) stop("Package 'duckdb' is required.")

  dir.create(dirname(db_path), recursive = TRUE, showWarnings = FALSE)

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_path, read_only = FALSE)
  .cyberarxiv_init_schema(con)
  con
}

#' Initialize database schema (idempotent)
#'
#' @noRd
.cyberarxiv_init_schema <- function(con) {
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS papers (
      paper_id        VARCHAR,
      link            VARCHAR,
      title           VARCHAR,
      authors         VARCHAR,
      abstract        VARCHAR,
      categories      VARCHAR,
      published_date  TIMESTAMP,
      updated_date    TIMESTAMP,
      ingested_at     TIMESTAMP DEFAULT now(),
      tag             VARCHAR,
      umap_x          DOUBLE,
      umap_y          DOUBLE
    );
  ")

  DBI::dbExecute(con, " CREATE INDEX IF NOT EXISTS idx_papers_paper_id ON papers(paper_id);")
  DBI::dbExecute(con, " CREATE INDEX IF NOT EXISTS idx_papers_published ON papers(published_date);")
  DBI::dbExecute(con, " CREATE INDEX IF NOT EXISTS idx_papers_updated ON papers(updated_date);")
}
