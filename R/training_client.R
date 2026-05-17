#' Training pipeline HTTP client
#'
#' Thin wrappers around the /training/* endpoints exposed by the Python
#' ML service. Used by the "Обучение" tab in the Shiny GUI but also usable
#' from the R console for batch automation.
#'
#' @name training_client
NULL


if (!exists("%||%", mode = "function")) {
  `%||%` <- function(a, b) if (is.null(a) || (is.atomic(a) && length(a) == 0)) b else a
}


.training_url <- function(ml_service_url = NULL) {
  if (is.null(ml_service_url)) ml_service_url <- Sys.getenv("ML_SERVICE_URL", "http://localhost:5001")
  ml_service_url
}


# Wraps an httr2 call so callers always get a list with $ok / $data / $error
# instead of a thrown condition. Critical for the Shiny UI — we want to
# surface the actual HTTP/JSON error message (e.g. "404 endpoint not found",
# "permission denied writing config"), not a silent NULL.
.training_call <- function(req) {
  out <- list(ok = FALSE, data = NULL, error = NULL, status = NA_integer_,
              body = NULL)
  resp <- tryCatch(
    httr2::req_error(req, is_error = function(r) FALSE) |> httr2::req_perform(),
    error = function(e) {
      out$error <<- paste0("transport: ", conditionMessage(e))
      NULL
    }
  )
  if (is.null(resp)) return(out)
  out$status <- httr2::resp_status(resp)
  body_txt <- tryCatch(httr2::resp_body_string(resp), error = function(e) "")
  out$body <- body_txt
  if (out$status >= 400) {
    detail <- tryCatch({
      j <- jsonlite::fromJSON(body_txt, simplifyVector = FALSE)
      if (!is.null(j$detail)) {
        if (is.character(j$detail)) j$detail else jsonlite::toJSON(j$detail, auto_unbox = TRUE)
      } else body_txt
    }, error = function(e) body_txt)
    out$error <- paste0("HTTP ", out$status, ": ", substr(detail, 1, 500))
    return(out)
  }
  out$data <- tryCatch(jsonlite::fromJSON(body_txt, simplifyVector = FALSE),
                       error = function(e) {
                         out$error <<- paste0("parse: ", conditionMessage(e))
                         NULL
                       })
  out$ok <- !is.null(out$data) && is.null(out$error)
  out
}


#' Get training-pipeline configuration
#'
#' @param ml_service_url Service URL.
#' @return list with classes, system_prompt, user_prompt_template, llm.
#'   On failure, returns NULL (use \code{training_get_config_safe} to inspect the error).
#' @export
training_get_config <- function(ml_service_url = NULL) {
  res <- training_get_config_safe(ml_service_url)
  if (!isTRUE(res$ok)) {
    warning("training_get_config: ", res$error)
    return(NULL)
  }
  res$data
}


#' Like training_get_config but returns the full call result (ok/data/error).
#' @param ml_service_url Service URL. Defaults to env var `ML_SERVICE_URL`.
#' @export
training_get_config_safe <- function(ml_service_url = NULL) {
  url <- .training_url(ml_service_url)
  req <- httr2::request(url) |>
    httr2::req_url_path("training/config") |>
    httr2::req_timeout(15)
  .training_call(req)
}


#' Update training-pipeline configuration
#'
#' Pass only the fields you want to change. Returns the saved config on
#' success, or a list with $error on failure (call \code{training_set_config_safe}
#' for the structured result).
#'
#' @param classes List of class definitions for the LLM labeler, e.g.
#'   \code{list(list(name="Malware", description="..."), ...)}. \code{NULL} keeps the current value.
#' @param system_prompt String. System prompt for the LLM labeler. \code{NULL} keeps the current value.
#' @param user_prompt_template String. User-message template (uses \code{\{title\}}/\code{\{abstract\}}
#'   placeholders). \code{NULL} keeps the current value.
#' @param llm Named list with LLM credentials/config (provider, model, api_key, base_url, ...).
#'   \code{NULL} keeps the current value.
#' @param ml_service_url Service URL. Defaults to env var `ML_SERVICE_URL`.
#' @export
training_set_config <- function(classes = NULL, system_prompt = NULL,
                                user_prompt_template = NULL, llm = NULL,
                                ml_service_url = NULL) {
  res <- training_set_config_safe(classes = classes,
                                  system_prompt = system_prompt,
                                  user_prompt_template = user_prompt_template,
                                  llm = llm,
                                  ml_service_url = ml_service_url)
  if (!isTRUE(res$ok)) {
    warning("training_set_config: ", res$error)
    return(NULL)
  }
  res$data
}


#' Like training_set_config but returns the full call result (ok/data/error).
#' Pass empty payload (everything NULL) and you'll get back the current config.
#' @inheritParams training_set_config
#' @export
training_set_config_safe <- function(classes = NULL, system_prompt = NULL,
                                     user_prompt_template = NULL, llm = NULL,
                                     ml_service_url = NULL) {
  url <- .training_url(ml_service_url)
  payload <- list()
  if (!is.null(classes)) {
    # Force classes to be a JSON array even if there's only one element.
    # Without I(), httr2 + jsonlite can collapse a 1-elem named list into
    # an object literal, which fails Pydantic List validation.
    payload$classes <- lapply(classes, function(c) {
      list(name = jsonlite::unbox(c$name %||% ""),
           description = jsonlite::unbox(c$description %||% ""))
    })
  }
  if (!is.null(system_prompt))         payload$system_prompt         <- jsonlite::unbox(system_prompt)
  if (!is.null(user_prompt_template))  payload$user_prompt_template  <- jsonlite::unbox(user_prompt_template)
  if (!is.null(llm)) {
    payload$llm <- lapply(llm, function(v) {
      if (length(v) <= 1) jsonlite::unbox(v) else v
    })
  }

  req <- httr2::request(url) |>
    httr2::req_url_path("training/config") |>
    httr2::req_body_json(payload, auto_unbox = FALSE) |>
    httr2::req_timeout(30)
  .training_call(req)
}


#' Start collect-arxiv job
#'
#' @param target Approximate target row count (e.g. 10000).
#' @param query Optional arXiv search_query override.
#' @param page_size Integer. Records per arXiv API request. Defaults to 200.
#' @param ml_service_url Service URL. Defaults to env var `ML_SERVICE_URL`.
#' @export
training_start_collect <- function(target, query = NULL, page_size = 200,
                                   ml_service_url = NULL) {
  url <- .training_url(ml_service_url)
  body <- list(target = as.integer(target),
               page_size = as.integer(page_size))
  if (!is.null(query) && nzchar(query)) body$query <- query

  resp <- httr2::request(url) |>
    httr2::req_url_path("training/collect") |>
    httr2::req_body_json(body, auto_unbox = TRUE) |>
    httr2::req_timeout(30) |>
    httr2::req_perform()
  httr2::resp_body_json(resp)$job_id
}


#' Start LLM-label job
#' @param raw_path Path (inside the ML container) to the parquet produced by
#'   \code{training_start_collect}.
#' @param max_rows Integer. Cap the number of rows to label; 0 means no cap.
#' @param ml_service_url Service URL. Defaults to env var `ML_SERVICE_URL`.
#' @export
training_start_label <- function(raw_path, max_rows = 0L,
                                 ml_service_url = NULL) {
  url <- .training_url(ml_service_url)
  body <- list(raw_path = raw_path, max_rows = as.integer(max_rows))

  resp <- httr2::request(url) |>
    httr2::req_url_path("training/label") |>
    httr2::req_body_json(body, auto_unbox = TRUE) |>
    httr2::req_timeout(30) |>
    httr2::req_perform()
  httr2::resp_body_json(resp)$job_id
}


#' Start export-to-Excel job
#' @param labeled_path Path to the parquet produced by \code{training_start_label}.
#' @param max_rows Integer. Cap rows to export; 0 means no cap.
#' @param ml_service_url Service URL. Defaults to env var `ML_SERVICE_URL`.
#' @export
training_start_export_excel <- function(labeled_path, max_rows = 0L,
                                        ml_service_url = NULL) {
  url <- .training_url(ml_service_url)
  body <- list(labeled_path = labeled_path, max_rows = as.integer(max_rows))

  resp <- httr2::request(url) |>
    httr2::req_url_path("training/export_excel") |>
    httr2::req_body_json(body, auto_unbox = TRUE) |>
    httr2::req_timeout(30) |>
    httr2::req_perform()
  httr2::resp_body_json(resp)$job_id
}


#' Start training job
#' @param excel_path Path to the .xlsx produced by \code{training_start_export_excel}
#'   (or hand-edited by the user).
#' @param model_name_out String. Name to save the trained model under in the ML service.
#' @param base_model String. Hugging Face model id used as the encoder backbone.
#' @param epochs Integer. Number of training epochs.
#' @param batch_size Integer. Mini-batch size.
#' @param lr Numeric. Initial learning rate.
#' @param max_length Integer. Max tokenised sequence length.
#' @param test_size Numeric (0–1). Fraction of data held out as the test split.
#' @param val_size Numeric (0–1). Fraction of remaining data used as the validation split.
#' @param mlflow_tracking_uri Optional MLflow URI override; defaults to the service's env.
#' @param ml_service_url Service URL. Defaults to env var `ML_SERVICE_URL`.
#' @export
training_start_train <- function(excel_path,
                                  model_name_out = "custom_model",
                                  base_model = "distilbert-base-uncased",
                                  epochs = 8L,
                                  batch_size = 16L,
                                  lr = 2e-5,
                                  max_length = 256L,
                                  test_size = 0.1,
                                  val_size = 0.1,
                                  mlflow_tracking_uri = NULL,
                                  ml_service_url = NULL) {
  url <- .training_url(ml_service_url)
  body <- list(
    excel_path = excel_path,
    model_name_out = model_name_out,
    base_model = base_model,
    epochs = as.integer(epochs),
    batch_size = as.integer(batch_size),
    lr = as.numeric(lr),
    max_length = as.integer(max_length),
    test_size = as.numeric(test_size),
    val_size = as.numeric(val_size)
  )
  if (!is.null(mlflow_tracking_uri) && nzchar(mlflow_tracking_uri))
    body$mlflow_tracking_uri <- mlflow_tracking_uri

  resp <- httr2::request(url) |>
    httr2::req_url_path("training/train") |>
    httr2::req_body_json(body, auto_unbox = TRUE) |>
    httr2::req_timeout(30) |>
    httr2::req_perform()
  httr2::resp_body_json(resp)$job_id
}


#' Poll job state
#' @param job_id Job identifier returned by one of the \code{training_start_*} calls.
#' @param ml_service_url Service URL. Defaults to env var `ML_SERVICE_URL`.
#' @export
training_get_job <- function(job_id, ml_service_url = NULL) {
  url <- .training_url(ml_service_url)
  resp <- tryCatch(
    httr2::request(url) |>
      httr2::req_url_path(paste0("training/jobs/", job_id)) |>
      httr2::req_timeout(15) |>
      httr2::req_perform(),
    error = function(e) NULL
  )
  if (is.null(resp)) return(NULL)
  if (httr2::resp_status(resp) >= 400) return(NULL)
  httr2::resp_body_json(resp)
}


#' List recent jobs
#' @param type Optional filter by job type (e.g. `"collect"`, `"label"`, `"train"`).
#'   `NULL` returns jobs of every type.
#' @param limit Integer. Maximum number of jobs to return (most recent first).
#' @param ml_service_url Service URL. Defaults to env var `ML_SERVICE_URL`.
#' @export
training_list_jobs <- function(type = NULL, limit = 50L, ml_service_url = NULL) {
  url <- .training_url(ml_service_url)
  req <- httr2::request(url) |>
    httr2::req_url_path("training/jobs") |>
    httr2::req_url_query(limit = as.integer(limit)) |>
    httr2::req_timeout(15)
  if (!is.null(type) && nzchar(type))
    req <- httr2::req_url_query(req, type = type)
  resp <- httr2::req_perform(req)
  httr2::resp_body_json(resp)
}


#' Cancel a job
#' @param job_id Job identifier returned by one of the \code{training_start_*} calls.
#' @param ml_service_url Service URL. Defaults to env var `ML_SERVICE_URL`.
#' @export
training_cancel_job <- function(job_id, ml_service_url = NULL) {
  url <- .training_url(ml_service_url)
  resp <- httr2::request(url) |>
    httr2::req_url_path(paste0("training/jobs/", job_id, "/cancel")) |>
    httr2::req_method("POST") |>
    httr2::req_timeout(15) |>
    httr2::req_perform()
  httr2::resp_body_json(resp)
}


#' List artifacts in a category (raw / labeled / excel)
#' @param category One of `"raw"`, `"labeled"`, `"excel"` — which artifact directory to list.
#' @param ml_service_url Service URL. Defaults to env var `ML_SERVICE_URL`.
#' @export
training_list_files <- function(category = c("raw", "labeled", "excel"),
                                ml_service_url = NULL) {
  category <- match.arg(category)
  url <- .training_url(ml_service_url)
  resp <- httr2::request(url) |>
    httr2::req_url_path(paste0("training/files/", category)) |>
    httr2::req_timeout(15) |>
    httr2::req_perform()
  httr2::resp_body_json(resp)
}


#' Download an artifact file
#' @param category One of `"raw"`, `"labeled"`, `"excel"`.
#' @param filename Name of the file to download (as returned by \code{training_list_files}).
#' @param dest_path Local path where the downloaded bytes are written.
#' @param ml_service_url Service URL. Defaults to env var `ML_SERVICE_URL`.
#' @export
training_download_file <- function(category, filename, dest_path,
                                   ml_service_url = NULL) {
  url <- .training_url(ml_service_url)
  resp <- httr2::request(url) |>
    httr2::req_url_path(paste0("training/files/", category, "/", filename)) |>
    httr2::req_timeout(120) |>
    httr2::req_perform()
  bin <- httr2::resp_body_raw(resp)
  writeBin(bin, dest_path)
  invisible(dest_path)
}


#' Reload all .pt models in the inference service.
#' @param ml_service_url Service URL. Defaults to env var `ML_SERVICE_URL`.
#' @export
training_reload_models <- function(ml_service_url = NULL) {
  url <- .training_url(ml_service_url)
  resp <- httr2::request(url) |>
    httr2::req_url_path("reload_models") |>
    httr2::req_method("POST") |>
    httr2::req_timeout(60) |>
    httr2::req_perform()
  httr2::resp_body_json(resp)
}
