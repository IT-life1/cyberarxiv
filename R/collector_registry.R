# Collector registry: discovery, loading, running, and standardising collectors.

# ── Null coalescing (local to this package) ───────────────────────────────────
`%||%` <- function(a, b) if (!is.null(a)) a else b

# ── Discovery paths ───────────────────────────────────────────────────────────

#' @noRd
.collector_dirs <- function(extra_dirs = NULL) {
  dirs <- character(0)

  # 1. Built-in package collectors
  builtin <- system.file("collectors", package = "cyberarxiv")
  if (nzchar(builtin) && dir.exists(builtin)) dirs <- c(dirs, builtin)

  # 2. User home directory
  user_dir <- file.path(path.expand("~"), ".cyberarxiv", "collectors")
  if (dir.exists(user_dir)) dirs <- c(dirs, user_dir)

  # 3. Environment variable override
  env_dir <- Sys.getenv("CYBERARXIV_COLLECTORS_DIR", unset = "")
  if (nzchar(env_dir) && dir.exists(env_dir)) dirs <- c(dirs, env_dir)

  # 4. Programmatic extra dirs
  if (!is.null(extra_dirs)) {
    valid <- extra_dirs[dir.exists(extra_dirs)]
    dirs  <- c(dirs, valid)
  }

  unique(dirs)
}

# ── Spec loading ──────────────────────────────────────────────────────────────

#' @noRd
.load_collector_spec <- function(path) {
  if (!requireNamespace("yaml", quietly = TRUE))
    stop("Package 'yaml' is required to load collector specs. ",
         "Install it with: install.packages('yaml')")

  spec <- yaml::read_yaml(path)

  missing_fields <- setdiff(c("name", "type"), names(spec))
  if (length(missing_fields))
    stop("Collector spec '", basename(path), "' is missing required field(s): ",
         paste(missing_fields, collapse = ", "))

  valid_types <- c("atom", "rss", "oai_pmh", "core_api", "r_script")
  if (!spec$type %in% valid_types)
    stop("Collector '", spec$name, "': unknown type '", spec$type, "'. ",
         "Must be one of: ", paste(valid_types, collapse = ", "))

  # Defaults
  if (is.null(spec$enabled))   spec$enabled   <- TRUE
  if (is.null(spec$label))     spec$label     <- spec$name
  if (is.null(spec$id_prefix)) spec$id_prefix <- ""

  spec$.path <- normalizePath(path, mustWork = FALSE)
  spec
}

#' @noRd
.list_collector_specs <- function(extra_dirs = NULL) {
  dirs <- .collector_dirs(extra_dirs)
  if (length(dirs) == 0L) return(list())

  yaml_files <- unlist(lapply(dirs, function(d) {
    list.files(d, pattern = "\\.ya?ml$", full.names = TRUE)
  }))

  specs <- list()
  for (f in yaml_files) {
    s <- tryCatch(
      .load_collector_spec(f),
      error = function(e) {
        warning("Skipping collector spec '", basename(f), "': ", conditionMessage(e))
        NULL
      }
    )
    if (!is.null(s)) specs[[s$name]] <- s  # later dirs overwrite earlier on name collision
  }
  specs
}

# ── Public API ────────────────────────────────────────────────────────────────

#' List available collector specs
#'
#' Returns a data.frame describing all collector YAML files found in the
#' discovery path. Use this to inspect which collectors are configured.
#'
#' @param extra_dirs Optional character vector of additional directories to scan.
#'
#' @return data.frame with columns: name, label, type, enabled.
#' @export
list_collectors <- function(extra_dirs = NULL) {
  specs <- .list_collector_specs(extra_dirs)
  if (length(specs) == 0L)
    return(data.frame(name = character(0), label = character(0),
                      type = character(0), enabled = logical(0),
                      stringsAsFactors = FALSE))

  data.frame(
    name    = vapply(specs, `[[`, character(1L), "name"),
    label   = vapply(specs, function(s) s$label  %||% s$name,  character(1L)),
    type    = vapply(specs, `[[`, character(1L), "type"),
    enabled = vapply(specs, function(s) isTRUE(s$enabled),      logical(1L)),
    stringsAsFactors = FALSE
  )
}

#' Collect papers from all (or selected) sources
#'
#' Runs every enabled collector and combines results into a single data.frame.
#' Each record carries a \code{source} column with the collector name.
#'
#' @param sources Character vector of collector names to run.
#'   \code{NULL} (default) runs every enabled collector.
#' @param max_results Maximum papers to fetch **per source**.
#' @param extra_dirs Additional directories to scan for collector YAML files.
#' @param param_overrides Named list of per-collector parameter overrides.
#'   E.g. \code{list(arxiv = list(params = list(search_query = "cat:cs.CR")))}
#'   merges into the spec before the collector runs.
#'
#' @return data.frame with columns:
#'   \code{id, source, link, title, authors, abstract, categories,
#'   published_date, updated_date}.
#' @export
collect_all <- function(sources = NULL, max_results = 100L, extra_dirs = NULL,
                        param_overrides = list()) {
  specs   <- .list_collector_specs(extra_dirs)
  enabled <- Filter(function(s) isTRUE(s$enabled), specs)

  if (!is.null(sources))
    enabled <- enabled[names(enabled) %in% sources]

  if (length(enabled) == 0L) {
    warning("No collectors matched the request. ",
            "Check list_collectors() and 'enabled' fields in YAML specs.")
    return(.empty_standard_df())
  }

  results <- list()
  for (nm in names(enabled)) {
    spec <- enabled[[nm]]
    # Apply per-collector overrides (shallow merge into spec fields)
    if (!is.null(param_overrides[[nm]])) {
      ovr <- param_overrides[[nm]]
      for (key in names(ovr)) spec[[key]] <- ovr[[key]]
    }
    message("Collector [", spec$type, "] '", spec$label %||% nm, "' — fetching up to ",
            max_results, " records...")
    df <- tryCatch(
      .run_collector(spec, as.integer(max_results)),
      error = function(e) {
        warning("Collector '", nm, "' failed: ", conditionMessage(e))
        NULL
      }
    )
    if (!is.null(df) && nrow(df) > 0L) {
      message("  -> ", nrow(df), " record(s) from '", nm, "'")
      results[[nm]] <- df
    } else {
      message("  -> 0 records from '", nm, "'")
    }
  }

  if (length(results) == 0L) return(.empty_standard_df())
  out <- do.call(rbind, results)
  rownames(out) <- NULL
  out
}

# ── Runner / dispatcher ───────────────────────────────────────────────────────

#' @noRd
.run_collector <- function(spec, max_results = 100L) {
  df <- switch(spec$type,
    atom     = .fetch_atom_feed(spec, max_results),
    rss      = .fetch_rss_feed(spec, max_results),
    oai_pmh  = .fetch_oai_pmh(spec, max_results),
    core_api = .fetch_core_api(spec, max_results),
    r_script = .run_r_script_collector(spec, max_results),
    stop("Unknown collector type: '", spec$type, "'")
  )
  .standardize_collector_output(df, spec)
}

# ── Standardisation ───────────────────────────────────────────────────────────

#' @noRd
.standardize_collector_output <- function(df, spec) {
  std_cols <- c("id", "link", "title", "authors", "abstract",
                "categories", "published_date", "updated_date", "source", "language")

  if (!is.data.frame(df) || nrow(df) == 0L) return(.empty_standard_df())

  # Apply id_prefix; normalize URL-based IDs to sha256 for compact, stable identifiers
  prefix <- spec$id_prefix %||% ""
  if ("id" %in% names(df)) {
    df$id <- vapply(df$id, function(raw_id) {
      id_norm <- if (grepl("^https?://", raw_id, ignore.case = TRUE))
        digest::digest(raw_id, algo = "sha256", serialize = FALSE)
      else
        raw_id
      paste0(prefix, id_norm)
    }, character(1L), USE.NAMES = FALSE)
  }

  # Fill missing columns with empty strings / NA
  for (col in std_cols) {
    if (!col %in% names(df))
      df[[col]] <- ""
  }

  # Set source; language from spec, then refine by text content
  df$source <- spec$name
  spec_lang <- spec$language %||% ""
  df$language <- vapply(seq_len(nrow(df)), function(i) {
    detected <- .detect_language(paste(df$title[i], df$abstract[i]))
    if (!is.na(detected) && nzchar(detected)) detected
    else if (nzchar(spec_lang)) spec_lang
    else NA_character_
  }, character(1L), USE.NAMES = FALSE)

  # Coerce character columns; replace NA with ""
  for (col in c("id", "link", "title", "authors", "abstract",
                "categories", "source", "language")) {
    df[[col]] <- as.character(df[[col]])
    df[[col]][is.na(df[[col]])] <- ""
  }

  # updated_date defaults to published_date when missing
  empty_upd <- is.na(df$updated_date) | !nzchar(df$updated_date)
  df$updated_date[empty_upd] <- df$published_date[empty_upd]

  # Drop records without id or title
  df <- df[nzchar(df$id) & nzchar(df$title), , drop = FALSE]

  df[std_cols]
}

#' @noRd
.detect_language <- function(text) {
  if (is.na(text) || !nzchar(trimws(text))) return(NA_character_)
  cyr   <- nchar(gsub("[^Ѐ-ӿ]", "", text))
  latin <- nchar(gsub("[^a-zA-Z]", "", text))
  total <- cyr + latin
  if (total == 0L) return(NA_character_)
  if (cyr / total > 0.25) "ru" else "en"
}

#' @noRd
.empty_standard_df <- function() {
  data.frame(
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
  )
}
