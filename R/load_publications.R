#' Load publications from local DuckDB storage
#'
#' Reads publications previously saved into the local DuckDB database (table `papers`).
#' By default returns all rows. Optional filters can limit the result by year, category,
#' or free-text search over title/abstract.
#'
#' @param db_path Path to DuckDB file. If NULL, uses internal default resolution:
#'   env `CYBERARXIV_DB_PATH` -> option `cyberarxiv.db_path` -> `data/cyberarxiv.duckdb`.
#' @param year Optional integer year to filter by `published_date` (e.g., 2025).
#' @param category Optional string. Keeps rows where `categories` contains this substring
#'   (case-insensitive). Note: `categories` are stored as human-readable names joined by ", ".
#' @param text Optional string. Case-insensitive search in `title` OR `abstract`.
#' @param limit Optional integer to limit number of rows returned (applied after filtering).
#' @param source Optional string. Keeps rows where `source` matches exactly
#'   (e.g. \code{"arxiv"}, \code{"habr"}). NULL returns all sources.
#' @param language Optional string. Keeps rows where `language` matches exactly
#'   (e.g. \code{"en"}, \code{"ru"}). NULL returns all languages.
#'
#' @return A data.frame (or tibble if `tibble` installed) with columns:
#'   paper_id, link, title, authors, abstract, categories,
#'   published_date, updated_date, ingested_at, tag, ml_results, source, language
#' @export
load_publications <- function(db_path = NULL,
                              year = NULL,
                              category = NULL,
                              text = NULL,
                              limit = NULL,
                              source = NULL,
                              language = NULL) {
  if (is.null(db_path)) db_path <- .cyberarxiv_db_path()

  if (!file.exists(db_path)) {
    return(.empty_papers_df())
  }

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  .cyberarxiv_ensure_duckdb_extensions(con)

  if (!("papers" %in% DBI::dbListTables(con))) {
    return(.empty_papers_df())
  }

  # Detect which optional columns exist to handle both old and new schema
  existing_cols  <- DBI::dbGetQuery(
    con,
    "SELECT column_name FROM information_schema.columns WHERE table_name = 'papers'"
  )$column_name
  select_ml_results <- if ("ml_results" %in% existing_cols) ", ml_results" else ", NULL as ml_results"
  select_source  <- if ("source"    %in% existing_cols) ", source"    else ", NULL as source"
  select_language <- if ("language" %in% existing_cols) ", language"  else ", NULL as language"

  sql <- paste0("
    SELECT
      paper_id, link, title, authors, abstract, categories,
      published_date, updated_date, ingested_at, tag",
      select_ml_results, select_source, select_language,
    "
    FROM papers
  ")
  where <- character(0)
  params <- list()

  if (!is.null(year)) {
    year <- as.integer(year)
    if (!is.na(year)) {
      where <- c(where, "EXTRACT(year FROM published_date) = ?")
      params <- c(params, list(year))
    }
  }

  if (!is.null(category) && nzchar(trimws(category))) {
    where <- c(where, "lower(categories) LIKE ?")
    params <- c(params, list(paste0("%", tolower(trimws(category)), "%")))
  }

  if (!is.null(text) && nzchar(trimws(text))) {
    where <- c(where, "(lower(title) LIKE ? OR lower(abstract) LIKE ?)")
    pat <- paste0("%", tolower(trimws(text)), "%")
    params <- c(params, list(pat, pat))
  }

  if (!is.null(source) && nzchar(trimws(source))) {
    where <- c(where, "source = ?")
    params <- c(params, list(trimws(source)))
  }

  if (!is.null(language) && nzchar(trimws(language))) {
    where <- c(where, "language = ?")
    params <- c(params, list(trimws(language)))
  }

  if (length(where)) {
    sql <- paste0(sql, " WHERE ", paste(where, collapse = " AND "))
  }

  sql <- paste0(sql, " ORDER BY updated_date DESC NULLS LAST, published_date DESC NULLS LAST")

  if (!is.null(limit)) {
    limit <- as.integer(limit)
    if (!is.na(limit) && limit > 0L) {
      sql <- paste0(sql, " LIMIT ", limit)
    }
  }

  df <- if (length(params)) {
    DBI::dbGetQuery(con, sql, params = params)
  } else {
    DBI::dbGetQuery(con, sql)
  }

  if (requireNamespace("tibble", quietly = TRUE)) {
    return(tibble::as_tibble(df))
  }
  df
}

#' @noRd
.empty_papers_df <- function() {
  df <- data.frame(
    paper_id = character(0),
    link = character(0),
    title = character(0),
    authors = character(0),
    abstract = character(0),
    categories = character(0),
    published_date = as.POSIXct(character(0), tz = "UTC"),
    updated_date = as.POSIXct(character(0), tz = "UTC"),
    ingested_at = as.POSIXct(character(0), tz = "UTC"),
    tag = character(0),
    ml_results = character(0),
    source = character(0),
    language = character(0),
    stringsAsFactors = FALSE
  )
  if (requireNamespace("tibble", quietly = TRUE)) tibble::as_tibble(df) else df
}
