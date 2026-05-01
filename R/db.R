#' Get path to DuckDB database file
#'
#' @noRd
.cyberarxiv_db_path <- function() {
  p <- Sys.getenv("CYBERARXIV_DB_PATH", unset = NA_character_)
  if (!is.na(p) && nzchar(p)) return(p)

  p <- getOption("cyberarxiv.db_path", default = NA_character_)
  if (!is.na(p) && nzchar(p)) return(p)

  # FIX: Use system.file() for installed package, fallback to relative path for dev
  pkg_path <- tryCatch(
    system.file("extdata", "cyberarxiv.duckdb", package = "cyberarxiv", mustWork = FALSE),
    error = function(e) ""
  )
  if (nzchar(pkg_path) && file.exists(dirname(pkg_path))) return(pkg_path)

  # Fallback for development / Docker (CWD-based)
  file.path("data", "cyberarxiv.duckdb")
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
      ml_tag          VARCHAR,
      ml_confidence   DOUBLE,
      source          VARCHAR,
      language        VARCHAR
    );
  ")

  # Migration: add columns that may be missing in older databases
  existing_cols <- DBI::dbGetQuery(
    con,
    "SELECT column_name FROM information_schema.columns WHERE table_name = 'papers'"
  )$column_name

  if (!"ml_tag" %in% existing_cols)
    DBI::dbExecute(con, "ALTER TABLE papers ADD COLUMN ml_tag VARCHAR;")

  if (!"ml_confidence" %in% existing_cols)
    DBI::dbExecute(con, "ALTER TABLE papers ADD COLUMN ml_confidence DOUBLE;")

  if (!"source" %in% existing_cols) {
    DBI::dbExecute(con, "ALTER TABLE papers ADD COLUMN source VARCHAR;")
    # Tag existing rows as 'arxiv' — the only source that existed before this migration
    DBI::dbExecute(con, "UPDATE papers SET source = 'arxiv' WHERE source IS NULL;")
  }

  if (!"language" %in% existing_cols) {
    DBI::dbExecute(con, "ALTER TABLE papers ADD COLUMN language VARCHAR;")
    # Existing rows are all arXiv (English)
    DBI::dbExecute(con, "UPDATE papers SET language = 'en' WHERE language IS NULL;")
  }

  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_papers_paper_id ON papers(paper_id);")
  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_papers_published ON papers(published_date);")
  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_papers_updated ON papers(updated_date);")
  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_papers_tag ON papers(tag);")
  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_papers_ml_tag ON papers(ml_tag);")
  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_papers_source ON papers(source);")
  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_papers_language ON papers(language);")
}

#' Add ml_tag_{task_id} and ml_confidence_{task_id} columns if they don't exist
#' @noRd
ensure_ml_task_columns <- function(con, task_id) {
  if (!grepl("^[A-Za-z0-9_]+$", task_id))
    stop("task_id must be snake_case (letters, digits, underscores only)")

  existing <- DBI::dbGetQuery(
    con,
    "SELECT column_name FROM information_schema.columns WHERE table_name = 'papers'"
  )$column_name

  tag_col  <- paste0("ml_tag_", task_id)
  conf_col <- paste0("ml_confidence_", task_id)

  if (!tag_col %in% existing)
    DBI::dbExecute(con, paste0("ALTER TABLE papers ADD COLUMN ", tag_col, " VARCHAR;"))
  if (!conf_col %in% existing)
    DBI::dbExecute(con, paste0("ALTER TABLE papers ADD COLUMN ", conf_col, " DOUBLE;"))

  invisible(NULL)
}

#' Return task IDs that have result columns in the papers table
#'
#' @param db_path Path to DuckDB file (default: resolved via env/option).
#' @return Character vector of task IDs, e.g. c("default", "malware").
#' @export
get_ml_task_ids <- function(db_path = NULL) {
  if (is.null(db_path)) db_path <- .cyberarxiv_db_path()
  if (!file.exists(db_path)) return(character(0))

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  cols <- DBI::dbGetQuery(
    con,
    "SELECT column_name FROM information_schema.columns WHERE table_name = 'papers'"
  )$column_name

  sub("^ml_tag_", "", grep("^ml_tag_", cols, value = TRUE))
}
