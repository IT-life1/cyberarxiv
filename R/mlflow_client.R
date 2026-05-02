#' MLflow client for cyberarxiv
#'
#' Functions to interact with the ML classification service (MLflow-based).
#' The ML service runs as a separate Docker container and provides an HTTP API
#' for classifying arXiv paper abstracts using a trained PyTorch model.
#'
#' @name mlflow_client
NULL

#' List models available in the ML service
#'
#' @param ml_service_url URL of the ML classification service
#' @return list with `models` (named list of model info) and `default` (string)
#' @export
list_ml_models <- function(ml_service_url = NULL) {
  if (is.null(ml_service_url))
    ml_service_url <- Sys.getenv("ML_SERVICE_URL", "http://localhost:5001")

  tryCatch({
    resp <- httr2::request(ml_service_url) |>
      httr2::req_url_path("models") |>
      httr2::req_timeout(seconds = 10) |>
      httr2::req_perform()
    httr2::resp_body_json(resp)
  }, error = function(e) {
    warning("Could not reach ML service: ", conditionMessage(e))
    list(models = list(), default = NULL)
  })
}

#' Classify papers using the ML service
#'
#' Sends paper abstracts to the ML classification service and returns
#' predicted tags with confidence scores.
#'
#' @param data data.frame with columns `id` and `abstract`
#' @param model Optional model name (e.g. \code{"general"}, \code{"malware"}).
#'   If NULL, the service picks the default model.
#' @param ml_service_url URL of the ML classification service (default: http://localhost:5001)
#' @param batch_size Number of papers to classify in one request (default: 50)
#'
#' @return data.frame with columns `id`, `ml_tag`, `ml_confidence`
#' @export
#'
#' @examples
#' \dontrun{
#' papers <- load_raw_data()
#' ml_results <- classify_with_ml(papers)
#' ml_results <- classify_with_ml(papers, model = "malware")
#' }
classify_with_ml <- function(data, model = NULL, ml_service_url = NULL, batch_size = 50) {
  if (is.null(ml_service_url)) {
    ml_service_url <- Sys.getenv("ML_SERVICE_URL", "http://localhost:5001")
  }

  if (!is.data.frame(data) || nrow(data) == 0) {
    return(data.frame(id = character(0), ml_tag = character(0), ml_confidence = numeric(0)))
  }

  if (!"abstract" %in% names(data) || !"id" %in% names(data)) {
    stop("Data must contain 'id' and 'abstract' columns")
  }

  # Check if ML service is available
  if (!ml_service_is_healthy(ml_service_url)) {
    warning("ML service is not available at ", ml_service_url, ". Returning empty results.")
    return(data.frame(
      id = data$id,
      ml_tag = NA_character_,
      ml_confidence = NA_real_,
      stringsAsFactors = FALSE
    ))
  }

  # Process in batches
  results <- list()
  n_batches <- ceiling(nrow(data) / batch_size)

  for (i in seq_len(n_batches)) {
    start_idx <- (i - 1) * batch_size + 1
    end_idx <- min(i * batch_size, nrow(data))
    batch <- data[start_idx:end_idx, ]

    # Prepare request payload
    payload <- list(
      papers = lapply(seq_len(nrow(batch)), function(j) {
        list(
          id = as.character(batch$id[j]),
          abstract = as.character(batch$abstract[j])
        )
      })
    )

    # Send request to ML service
    response <- tryCatch({
      req <- httr2::request(ml_service_url) |>
        httr2::req_url_path("classify") |>
        httr2::req_body_json(payload) |>
        httr2::req_timeout(seconds = 120)
      if (!is.null(model) && nzchar(model))
        req <- httr2::req_url_query(req, model = model)
      httr2::req_perform(req)
    }, error = function(e) {
      warning("ML service request failed for batch ", i, ": ", conditionMessage(e))
      NULL
    })

    if (is.null(response)) {
      # Fill with NA for failed batch
      results[[i]] <- data.frame(
        id = batch$id,
        ml_tag = NA_character_,
        ml_confidence = NA_real_,
        stringsAsFactors = FALSE
      )
      next
    }

    # Parse response
    resp_data <- tryCatch({
      httr2::resp_body_json(response)
    }, error = function(e) {
      warning("Failed to parse ML service response for batch ", i, ": ", conditionMessage(e))
      NULL
    })

    if (is.null(resp_data)) {
      results[[i]] <- data.frame(
        id = batch$id,
        ml_tag = NA_character_,
        ml_confidence = NA_real_,
        stringsAsFactors = FALSE
      )
      next
    }

    # Convert response to data.frame
    batch_results <- do.call(rbind, lapply(resp_data$results, function(r) {
      data.frame(
        id = r$id,
        ml_tag = r$tag,
        ml_confidence = as.numeric(r$confidence),
        stringsAsFactors = FALSE
      )
    }))
    results[[i]] <- batch_results

    # Small delay between batches to avoid overloading the service
    if (i < n_batches) Sys.sleep(0.5)
  }

  do.call(rbind, results)
}

#' Update ML tags in the database
#'
#' Takes ML classification results and writes them to task-specific columns
#' (\code{ml_tag_<task_id>} and \code{ml_confidence_<task_id>}). Columns are
#' created automatically on first use. Results from different tasks never
#' overwrite each other.
#'
#' @param ml_results data.frame with columns `id`, `ml_tag`, `ml_confidence`
#'   as returned by `classify_with_ml()`
#' @param task_id Task identifier matching a key in \code{inst/ml_tasks.yml}
#'   (default: \code{"default"}). Determines which columns are written.
#' @param db_path optional path to duckdb file
#'
#' @return invisible list with update count
#' @export
#'
#' @examples
#' \dontrun{
#' ml_results <- classify_with_ml(papers)
#' update_ml_tags(ml_results, task_id = "default")
#' update_ml_tags(ml_results, task_id = "malware")
#' }
update_ml_tags <- function(ml_results, task_id = "default", db_path = NULL) {
  if (!grepl("^[A-Za-z0-9_]+$", task_id))
    stop("task_id must be snake_case (letters, digits, underscores only)")

  if (is.null(db_path)) db_path <- .cyberarxiv_db_path()

  if (!is.data.frame(ml_results) || nrow(ml_results) == 0)
    return(invisible(list(updated = 0L)))

  con <- .cyberarxiv_connect(db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  tag_col  <- paste0("ml_tag_", task_id)
  conf_col <- paste0("ml_confidence_", task_id)

  ensure_ml_task_columns(con, task_id)

  stage_df <- data.frame(
    paper_id      = as.character(ml_results$id),
    ml_tag        = as.character(ml_results$ml_tag),
    ml_confidence = as.numeric(ml_results$ml_confidence),
    stringsAsFactors = FALSE
  )
  stage_df <- stage_df[!is.na(stage_df$ml_tag) & nzchar(stage_df$ml_tag), ]

  if (nrow(stage_df) == 0)
    return(invisible(list(updated = 0L)))

  DBI::dbExecute(con, "BEGIN TRANSACTION;")
  updated <- tryCatch({
    DBI::dbWriteTable(con, "stg_ml_tags", stage_df, overwrite = TRUE)

    n <- DBI::dbExecute(con, sprintf("
      UPDATE papers AS p
      SET
        %s = s.ml_tag,
        %s = s.ml_confidence
      FROM stg_ml_tags AS s
      WHERE p.paper_id = s.paper_id
        AND s.paper_id IS NOT NULL
        AND s.paper_id <> '';
    ", tag_col, conf_col))

    DBI::dbExecute(con, "DROP TABLE IF EXISTS stg_ml_tags;")
    DBI::dbExecute(con, "COMMIT;")
    n
  }, error = function(e) {
    DBI::dbExecute(con, "ROLLBACK;")
    stop("update_ml_tags failed: ", conditionMessage(e))
  })

  invisible(list(updated = as.integer(updated)))
}

#' Check if ML service is healthy
#'
#' @param ml_service_url URL of the ML classification service
#' @return logical TRUE if service is responding
#' @export
ml_service_is_healthy <- function(ml_service_url = NULL) {
  if (is.null(ml_service_url)) {
    ml_service_url <- Sys.getenv("ML_SERVICE_URL", "http://localhost:5001")
  }

  tryCatch({
    resp <- httr2::request(ml_service_url) |>
      httr2::req_url_path("health") |>
      httr2::req_timeout(seconds = 5) |>
      httr2::req_perform()
    httr2::resp_status(resp) == 200
  }, error = function(e) FALSE)
}

#' Path to the user-writable override yaml for ML tasks.
#'
#' The package-bundled \code{inst/ml_tasks.yml} is read-only after install.
#' New tasks registered via the training pipeline land in this override
#' file, which lives next to the rest of the training-pipeline state.
#' @noRd
.ml_tasks_override_path <- function() {
  base <- Sys.getenv("TRAINING_DATA_DIR", unset = "")
  if (!nzchar(base)) {
    candidates <- c(
      file.path(getwd(), "training_data"),
      file.path(path.expand("~"), ".cyberarxiv", "training_data")
    )
    base <- candidates[file.exists(candidates)][1]
    if (is.na(base) || !nzchar(base))
      base <- candidates[[1]]
  }
  file.path(base, "config", "ml_tasks_override.yml")
}

#' Load ML task definitions from inst/ml_tasks.yml + user override
#'
#' Tasks defined in the override yaml take precedence over package-bundled
#' tasks with the same name, so users can both add new tasks and tweak the
#' built-in ones without editing the installed package.
#'
#' @return Named list of tasks, each with \code{label} and \code{models} (named list lang→model).
#' @export
load_ml_tasks <- function() {
  builtin_path <- system.file("ml_tasks.yml", package = "cyberarxiv")
  builtin <- if (nzchar(builtin_path) && file.exists(builtin_path)) {
    tryCatch(yaml::read_yaml(builtin_path), error = function(e) list())
  } else {
    list(
      default = list(label = "Общая классификация",
                     models = list(en = "best_model", ru = "russian"))
    )
  }

  override_path <- .ml_tasks_override_path()
  override <- if (file.exists(override_path)) {
    tryCatch(yaml::read_yaml(override_path), error = function(e) list())
  } else {
    list()
  }

  merged <- builtin
  if (is.list(override)) {
    for (nm in names(override)) merged[[nm]] <- override[[nm]]
  }

  lapply(merged, function(task) {
    list(
      label  = task$label  %||% "—",
      models = task$models %||% list()
    )
  })
}

#' Register a trained model as a new ML task
#'
#' Appends a task entry to the user override yaml (\code{training_data/config/ml_tasks_override.yml}).
#' Subsequent calls to \code{load_ml_tasks()} will see the new task without
#' restarting the Shiny app or rebuilding the package.
#'
#' @param task_name snake_case identifier, e.g. \code{"my_grok_model"}.
#' @param label Human-readable label shown in dropdowns.
#' @param model_name Name of the .pt file (without extension) in MODELS_DIR.
#' @param language Two-letter language code (\code{"en"} / \code{"ru"} / etc).
#' @export
register_ml_task <- function(task_name, label, model_name, language = "en") {
  task_name <- trimws(task_name)
  if (!nzchar(task_name) || grepl("[^A-Za-z0-9_]", task_name))
    stop("task_name must be non-empty snake_case (letters/digits/underscore)")

  override_path <- .ml_tasks_override_path()
  dir.create(dirname(override_path), recursive = TRUE, showWarnings = FALSE)

  current <- if (file.exists(override_path)) {
    tryCatch(yaml::read_yaml(override_path), error = function(e) list())
  } else {
    list()
  }
  if (!is.list(current)) current <- list()

  models <- list()
  models[[language]] <- model_name
  current[[task_name]] <- list(
    label  = label,
    models = models
  )

  yaml::write_yaml(current, override_path)
  invisible(current)
}

#' List ML tasks with availability information
#'
#' Returns the task list annotated with which models are currently loaded
#' in the ML service, so callers can show which tasks are actionable.
#'
#' @param ml_service_url URL of the ML service.
#' @return Named list; each entry has \code{label}, \code{models},
#'   \code{available_models} (subset of models that are loaded).
#' @export
list_ml_tasks <- function(ml_service_url = NULL) {
  if (is.null(ml_service_url))
    ml_service_url <- Sys.getenv("ML_SERVICE_URL", "http://localhost:5001")

  tasks   <- load_ml_tasks()
  loaded  <- tryCatch(names(list_ml_models(ml_service_url)$models),
                      error = function(e) character(0))

  lapply(tasks, function(task) {
    avail <- Filter(function(m) m %in% loaded, task$models)
    task$available_models <- avail
    task
  })
}

#' Full ETL pipeline with ML classification
#'
#' Extended ETL pipeline that also runs ML classification on fetched papers
#' and updates the database with ML-predicted tags. Language routing is
#' automatic: papers are split by the \code{language} column and sent to
#' the model defined for that language in the chosen task. If a model for
#' a particular language is not loaded in the service, those papers are
#' skipped and their \code{ml_tag} stays empty.
#'
#' @param max_results How many papers to load.
#' @param ml_service_url URL of the ML service (default from env var ML_SERVICE_URL).
#' @param task Task name from \code{inst/ml_tasks.yml} (default: \code{"default"}).
#'   Use \code{list_ml_tasks()} to see available tasks and their loaded models.
#' @param sources Character vector of collector names to run.
#' @param collectors_dir Additional directory to scan for collector YAML files.
#' @param db_path Path to DuckDB file. If NULL, uses the package default.
#'
#' @export
etl_with_ml <- function(max_results = 100, ml_service_url = NULL,
                        task = "default", sources = NULL, collectors_dir = NULL,
                        db_path = NULL) {
  etl(max_results = max_results, sources = sources, collectors_dir = collectors_dir,
      db_path = db_path)

  if (is.null(ml_service_url))
    ml_service_url <- Sys.getenv("ML_SERVICE_URL", "http://localhost:5001")

  if (!ml_service_is_healthy(ml_service_url)) {
    message("ML service not available at ", ml_service_url, ". Skipping ML classification.")
    return(invisible(list(updated = 0L)))
  }

  tasks <- load_ml_tasks()
  if (!task %in% names(tasks))
    stop("Unknown ML task '", task, "'. Available: ", paste(names(tasks), collapse = ", "))
  language_models <- tasks[[task]]$models

  data <- load_publications(db_path = db_path)
  if (nrow(data) == 0L) return(invisible(list(updated = 0L)))

  available <- tryCatch(
    names(list_ml_models(ml_service_url)$models),
    error = function(e) character(0)
  )

  ml_results <- .classify_by_language(data, language_models, available, ml_service_url)

  if (is.null(ml_results) || nrow(ml_results) == 0L)
    return(invisible(list(updated = 0L)))

  update_stats <- update_ml_tags(ml_results, task_id = task)
  message("ML classification complete [task=", task, "]. Updated ",
          update_stats$updated, " records.")
  invisible(update_stats)
}

#' @noRd
.classify_by_language <- function(data, language_models, available_models, ml_service_url) {
  if (!is.data.frame(data) || nrow(data) == 0L) return(NULL)

  lang_col <- if ("language" %in% names(data)) data$language else rep("", nrow(data))
  lang_col[is.na(lang_col) | !nzchar(lang_col)] <- "en"

  results <- list()

  for (lang in unique(lang_col)) {
    group <- data[lang_col == lang, , drop = FALSE]
    if (nrow(group) == 0L) next

    model_name <- language_models[[lang]] %||% NULL

    if (is.null(model_name) || !nzchar(model_name)) {
      message("  Skipping ML for language='", lang, "' (task has no model for this language).")
      next
    }

    if (length(available_models) > 0L && !model_name %in% available_models) {
      message("  Skipping ML for language='", lang, "': model '", model_name,
              "' not loaded in service.")
      next
    }

    message("  Classifying ", nrow(group), " paper(s) [lang=", lang,
            "] with model='", model_name, "'...")

    res <- tryCatch(
      classify_with_ml(group, model = model_name, ml_service_url = ml_service_url),
      error = function(e) {
        message("  ML error for lang='", lang, "': ", conditionMessage(e))
        NULL
      }
    )
    if (!is.null(res)) results[[lang]] <- res
  }

  if (length(results) == 0L) return(NULL)
  do.call(rbind, results)
}
