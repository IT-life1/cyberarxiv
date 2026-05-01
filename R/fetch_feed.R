# Generic feed fetchers: Atom, RSS, OAI-PMH
# All return a data.frame with columns:
#   id, link, title, authors, abstract, categories, published_date, updated_date
# The 'source' column is added later by .standardize_collector_output().

# ── Atom ──────────────────────────────────────────────────────────────────────

#' @noRd
.fetch_atom_feed <- function(spec, max_results = 100L) {
  url       <- spec$url %||% stop("'url' is required for atom collector '", spec$name, "'")
  ns_uri    <- spec$namespace %||% "http://www.w3.org/2005/Atom"
  ns        <- c(atom = ns_uri)
  item_xp   <- spec$item_xpath %||% ".//atom:entry"
  page_size <- as.integer(spec$pagination$page_size %||% 100L)
  rate_secs <- as.numeric(spec$rate_limit_secs %||% 0.5)
  retry_n   <- as.integer(spec$retry %||% 3L)
  field_map <- spec$fields     %||% list()
  xforms    <- spec$transforms %||% list()

  out      <- list()
  start    <- 0L
  seen_ids <- character(0)

  while (TRUE) {
    collected <- sum(vapply(out, nrow, integer(1L)))
    n <- min(page_size, max_results - collected)
    if (n <= 0L) break

    q_params <- c(
      spec$params %||% list(),
      .pagination_params(spec$pagination, start, n)
    )

    doc <- tryCatch(
      .http_fetch_xml(url, q_params, retry_n),
      error = function(e) {
        warning("Atom fetch failed (start=", start, ", source='", spec$name, "'): ",
                conditionMessage(e))
        NULL
      }
    )
    if (is.null(doc)) break

    entries <- xml2::xml_find_all(doc, item_xp, ns)
    if (length(entries) == 0L) break

    batch <- .parse_atom_entries(entries, ns, field_map, xforms)
    if (nrow(batch) == 0L) break

    batch <- batch[!batch$id %in% seen_ids, , drop = FALSE]
    if (nrow(batch) == 0L) break

    seen_ids <- c(seen_ids, batch$id)
    out[[length(out) + 1L]] <- batch
    start <- start + nrow(batch)

    pag_type <- spec$pagination$type %||% "none"
    if (pag_type == "none") break
    Sys.sleep(rate_secs)
  }

  if (length(out) == 0L) return(.empty_feed_df())
  res <- do.call(rbind, out)
  rownames(res) <- NULL
  res
}

#' @noRd
.parse_atom_entries <- function(entries, ns, field_map, transforms) {
  # Default Atom field definitions
  defaults <- list(
    id             = list(xpath = "./atom:id",              multi = FALSE),
    title          = list(xpath = "./atom:title",           multi = FALSE),
    abstract       = list(xpath = "./atom:summary",         multi = FALSE),
    link           = list(xpath = "./atom:id",              multi = FALSE),
    published_date = list(xpath = "./atom:published",       multi = FALSE),
    updated_date   = list(xpath = "./atom:updated",         multi = FALSE),
    authors        = list(xpath = "./atom:author/atom:name",multi = TRUE, join = "; "),
    categories     = list(xpath = "./atom:category",        multi = TRUE,
                          attr = "term", join = "; ")
  )

  # Apply user overrides
  for (nm in names(field_map)) {
    fm <- field_map[[nm]]
    defaults[[nm]] <- if (is.character(fm)) list(xpath = fm, multi = FALSE) else fm
  }

  extract <- function(entry, fdef) {
    if (is.null(fdef$xpath)) return("")
    nodes <- xml2::xml_find_all(entry, fdef$xpath, ns)
    if (length(nodes) == 0L) return("")
    vals <- if (!is.null(fdef$attr)) {
      v <- xml2::xml_attr(nodes, fdef$attr); v[!is.na(v)]
    } else {
      trimws(xml2::xml_text(nodes))
    }
    if (isTRUE(fdef$multi)) paste(vals, collapse = fdef$join %||% "; ")
    else if (length(vals) == 0L) "" else vals[[1L]]
  }

  rows <- lapply(entries, function(e) {
    as.data.frame(lapply(defaults, function(fd) extract(e, fd)),
                  stringsAsFactors = FALSE)
  })
  df <- do.call(rbind, rows)

  # Apply transforms
  for (col in names(transforms)) {
    tf <- .get_transform(transforms[[col]])
    if (!is.null(tf) && col %in% names(df))
      df[[col]] <- vapply(df[[col]], tf, character(1L))
  }
  df
}

# ── RSS ───────────────────────────────────────────────────────────────────────

#' @noRd
.fetch_rss_feed <- function(spec, max_results = 100L) {
  url     <- spec$url %||% stop("'url' is required for rss collector '", spec$name, "'")
  retry_n <- as.integer(spec$retry %||% 3L)

  doc <- tryCatch(
    .http_fetch_xml(url, list(), retry_n),
    error = function(e) {
      warning("RSS fetch failed ('", spec$name, "'): ", conditionMessage(e)); NULL
    }
  )
  if (is.null(doc)) return(.empty_feed_df())

  items <- xml2::xml_find_all(doc, ".//item")
  if (length(items) == 0L) return(.empty_feed_df())

  # Field name map: standard col -> RSS element name
  fm <- spec$fields %||% list()
  fld <- function(std, default) fm[[std]] %||% default

  get_text <- function(item, elem) {
    if (is.null(elem) || !nzchar(elem)) return("")
    node <- xml2::xml_find_first(item, paste0("./", elem))
    trimws(xml2::xml_text(node, trim = TRUE) %||% "")
  }

  id_elem   <- fld("id",             "guid")
  link_elem <- fld("link",           "link")

  rows <- lapply(items, function(item) {
    id_val   <- get_text(item, id_elem)
    link_val <- get_text(item, link_elem)
    if (!nzchar(id_val)) id_val <- link_val

    data.frame(
      id             = id_val,
      title          = get_text(item, fld("title",          "title")),
      abstract       = get_text(item, fld("abstract",       "description")),
      link           = link_val,
      authors        = get_text(item, fld("authors",        "")),
      categories     = get_text(item, fld("categories",     "")),
      published_date = get_text(item, fld("published_date", "pubDate")),
      updated_date   = get_text(item, fld("updated_date",   "")),
      stringsAsFactors = FALSE
    )
  })

  df <- do.call(rbind, rows)
  rownames(df) <- NULL

  for (col in names(spec$transforms %||% list())) {
    tf <- .get_transform(spec$transforms[[col]])
    if (!is.null(tf) && col %in% names(df))
      df[[col]] <- vapply(df[[col]], tf, character(1L))
  }

  if (max_results < nrow(df)) df <- df[seq_len(max_results), , drop = FALSE]
  df
}

# ── OAI-PMH ──────────────────────────────────────────────────────────────────

#' @noRd
.fetch_oai_pmh <- function(spec, max_results = 100L) {
  url        <- spec$url %||% stop("'url' is required for oai_pmh collector '", spec$name, "'")
  oai_cfg    <- spec$oai %||% list()
  meta_pfx   <- oai_cfg$metadata_prefix %||% "oai_dc"
  oai_set    <- oai_cfg$set %||% ""
  oai_from   <- spec$oai_from %||% ""
  page_size  <- as.integer(spec$page_size %||% 100L)
  rate_secs  <- as.numeric(spec$rate_limit_secs %||% 1.0)
  retry_n    <- as.integer(spec$retry %||% 3L)
  max_pages  <- as.integer(spec$max_pages %||% 500L)
  kw_filter  <- spec$filter_keywords %||% character(0)

  oai_ns           <- c(oai = "http://www.openarchives.org/OAI/2.0/")
  out              <- list()
  resumption_token <- NULL
  page_count       <- 0L

  repeat {
    if (page_count >= max_pages) {
      message("  [oai_pmh] max_pages (", max_pages, ") reached for '", spec$name, "'")
      break
    }
    page_count <- page_count + 1L

    if (!is.null(resumption_token)) {
      params <- list(verb = "ListRecords", resumptionToken = resumption_token)
    } else {
      params <- list(verb = "ListRecords", metadataPrefix = meta_pfx)
      if (nzchar(oai_set)) params$set <- oai_set
      if (nzchar(oai_from)) params$from <- oai_from
    }

    doc <- tryCatch(
      .http_fetch_xml(url, params, retry_n),
      error = function(e) {
        warning("OAI-PMH fetch failed ('", spec$name, "'): ", conditionMessage(e)); NULL
      }
    )
    if (is.null(doc)) break

    # Check for OAI errors (try both namespaced and plain)
    err_node <- xml2::xml_find_first(doc, ".//oai:error", oai_ns)
    if (inherits(err_node, "xml_missing"))
      err_node <- xml2::xml_find_first(doc, ".//error")
    if (!is.na(xml2::xml_text(err_node, trim = TRUE))) {
      err_code <- xml2::xml_attr(err_node, "code")
      err_code <- if (is.na(err_code) || !nzchar(err_code)) "unknown" else err_code
      if (err_code == "noRecordsMatch") break
      warning("OAI-PMH error '", spec$name, "': ", xml2::xml_text(err_node))
      break
    }

    # Try namespaced XPath first, fall back to plain (for servers without default NS)
    records <- xml2::xml_find_all(doc, ".//oai:record", oai_ns)
    if (length(records) == 0L)
      records <- xml2::xml_find_all(doc, ".//record")
    if (length(records) == 0L) break

    batch <- .parse_oai_dc_records(records, kw_filter)
    if (nrow(batch) > 0L) out[[length(out) + 1L]] <- batch

    collected <- sum(vapply(out, nrow, integer(1L)))
    if (collected >= max_results) break

    token_node <- xml2::xml_find_first(doc, ".//oai:resumptionToken", oai_ns)
    if (inherits(token_node, "xml_missing"))
      token_node <- xml2::xml_find_first(doc, ".//resumptionToken")
    tok <- trimws(xml2::xml_text(token_node, trim = TRUE))
    if (is.na(tok) || !nzchar(tok)) break
    resumption_token <- tok
    Sys.sleep(rate_secs)
  }

  if (length(out) == 0L) return(.empty_feed_df())
  res <- do.call(rbind, out)
  rownames(res) <- NULL
  if (nrow(res) > max_results) res <- res[seq_len(max_results), , drop = FALSE]
  res
}

#' @noRd
.parse_oai_dc_records <- function(records, kw_filter = character(0)) {
  # Dublin Core namespace
  dc_ns <- c(
    oai    = "http://www.openarchives.org/OAI/2.0/",
    dc     = "http://purl.org/dc/elements/1.1/",
    oai_dc = "http://www.openarchives.org/OAI/2.0/oai_dc/"
  )

  txt_all <- function(node, xpath) {
    vals <- trimws(xml2::xml_text(xml2::xml_find_all(node, xpath, dc_ns)))
    paste(vals[nzchar(vals)], collapse = "; ")
  }
  txt1 <- function(node, xpath) {
    v <- trimws(xml2::xml_text(xml2::xml_find_first(node, xpath, dc_ns)))
    if (is.na(v)) "" else v
  }

  rows <- lapply(records, function(rec) {
    # Skip deleted records
    header <- xml2::xml_find_first(rec, ".//oai:header", dc_ns)
    if (!is.na(xml2::xml_attr(header, "status")) &&
        xml2::xml_attr(header, "status") == "deleted") return(NULL)

    id_raw    <- txt1(rec, ".//oai:header/oai:identifier")
    datestamp <- txt1(rec, ".//oai:header/oai:datestamp")
    md        <- xml2::xml_find_first(rec, ".//oai_dc:dc", dc_ns)
    if (is.na(xml2::xml_text(md, trim = TRUE))) return(NULL)

    title    <- txt1(md,    ".//dc:title")
    abstract <- txt_all(md, ".//dc:description")
    authors  <- txt_all(md, ".//dc:creator")
    cats     <- txt_all(md, ".//dc:subject")
    pub_date <- txt1(md,    ".//dc:date")
    if (!nzchar(pub_date)) pub_date <- datestamp

    # Try dc:identifier for a better link
    ids <- trimws(xml2::xml_text(xml2::xml_find_all(md, ".//dc:identifier", dc_ns)))
    link <- ids[grepl("^https?://", ids)][1L]
    if (is.na(link)) link <- id_raw

    # Optional keyword filter
    if (length(kw_filter) > 0L) {
      haystack <- tolower(paste(title, abstract, cats))
      matches  <- vapply(tolower(kw_filter), grepl, logical(1L),
                         x = haystack, fixed = TRUE)
      if (!any(matches)) return(NULL)
    }

    data.frame(
      id             = id_raw,
      title          = title,
      abstract       = abstract,
      link           = link %||% "",
      authors        = authors,
      categories     = cats,
      published_date = pub_date,
      updated_date   = pub_date,
      stringsAsFactors = FALSE
    )
  })

  rows <- Filter(Negate(is.null), rows)
  if (length(rows) == 0L) return(.empty_feed_df())
  do.call(rbind, rows)
}

# ── CORE REST API v3 ──────────────────────────────────────────────────────────

#' @noRd
.fetch_core_api <- function(spec, max_results = 100L) {
  url       <- spec$url %||% "https://api.core.ac.uk/v3/search/works/"
  api_key <- spec$api_key %||% ""
  if (!nzchar(api_key)) {
    key_env <- spec$api_key_env %||% "CORE_API_KEY"
    api_key <- Sys.getenv(key_env, unset = "")
  }
  if (!nzchar(api_key))
    stop("CORE API key not found. Set 'api_key' in core.yml or the 'CORE_API_KEY' ",
         "environment variable. Register at https://core.ac.uk/services/api")

  query     <- trimws(spec$query %||%
    "cybersecurity OR malware OR \"information security\" OR vulnerability")
  page_size <- min(as.integer(spec$page_size %||% 10L), 10L)
  rate_secs <- as.numeric(spec$rate_limit_secs %||% 1.0)
  retry_n   <- as.integer(spec$retry %||% 3L)
  kw_filter <- spec$filter_keywords %||% character(0)

  out    <- list()
  offset <- 0L

  repeat {
    collected <- sum(vapply(out, nrow, integer(1L)))
    limit     <- min(page_size, max_results - collected)
    if (limit <= 0L) break

    resp_json <- tryCatch(
      .http_fetch_core_api(url, api_key, query, offset, limit, retry_n),
      error = function(e) {
        warning("CORE API fetch failed (offset=", offset, ", source='",
                spec$name, "'): ", conditionMessage(e))
        NULL
      }
    )
    if (is.null(resp_json)) break

    results <- resp_json$results
    if (is.null(results) || length(results) == 0L) break

    batch <- .parse_core_api_results(results, kw_filter)
    if (nrow(batch) > 0L) out[[length(out) + 1L]] <- batch

    if (length(results) < limit) break  # last page
    offset <- offset + length(results)
    Sys.sleep(rate_secs)
  }

  if (length(out) == 0L) return(.empty_feed_df())
  res <- do.call(rbind, out)
  rownames(res) <- NULL
  if (nrow(res) > max_results) res <- res[seq_len(max_results), , drop = FALSE]
  res
}

#' @noRd
.http_fetch_core_api <- function(url, api_key, query, offset, limit, retry_n = 3L) {
  req <- httr2::request(url) |>
    httr2::req_headers(Authorization = paste("Bearer", api_key)) |>
    httr2::req_user_agent("cyberarxiv/0.1.0") |>
    httr2::req_timeout(seconds = 60)

  # CORE API returns 500 when offset=0 is passed explicitly — omit it on first page
  if (offset > 0L) {
    req <- httr2::req_url_query(req, q = query, offset = offset, limit = limit)
  } else {
    req <- httr2::req_url_query(req, q = query, limit = limit)
  }

  resp <- httr2::req_perform(req)

  if (httr2::resp_status(resp) != 200L)
    stop("HTTP ", httr2::resp_status(resp), " from CORE API")

  httr2::resp_body_json(resp)
}

#' @noRd
.parse_core_api_results <- function(results, kw_filter = character(0)) {
  rows <- lapply(results, function(item) {
    id    <- as.character(item$id %||% "")
    title <- trimws(item$title %||% "")

    abstract <- trimws(item$abstract %||% "")

    authors <- ""
    if (!is.null(item$authors) && length(item$authors) > 0L) {
      names_vec <- vapply(item$authors, function(a) a$name %||% "", character(1L))
      authors   <- paste(names_vec[nzchar(names_vec)], collapse = "; ")
    }

    pub_date <- as.character(item$publishedDate %||% item$depositedDate %||% "")

    # CORE work page as canonical link; downloadUrl as fallback
    link <- if (nzchar(id)) paste0("https://core.ac.uk/works/", id) else ""
    if (!nzchar(link))
      link <- as.character(item$downloadUrl %||% "")

    categories <- paste(unlist(item$fieldOfStudy %||% list()), collapse = "; ")

    if (length(kw_filter) > 0L) {
      haystack <- tolower(paste(title, abstract, categories))
      matches  <- vapply(tolower(kw_filter), grepl, logical(1L),
                         x = haystack, fixed = TRUE)
      if (!any(matches)) return(NULL)
    }

    data.frame(
      id             = id,
      title          = title,
      abstract       = abstract,
      link           = link,
      authors        = authors,
      categories     = categories,
      published_date = pub_date,
      updated_date   = pub_date,
      stringsAsFactors = FALSE
    )
  })

  rows <- Filter(Negate(is.null), rows)
  if (length(rows) == 0L) return(.empty_feed_df())
  do.call(rbind, rows)
}

# ── R script collector ────────────────────────────────────────────────────────

#' @noRd
.run_r_script_collector <- function(spec, max_results) {
  script_path <- spec$script %||%
    stop("'script' field is required for r_script collector '", spec$name, "'")

  if (!grepl("^/|^[A-Za-z]:", script_path)) {
    spec_dir    <- dirname(spec$.path %||% ".")
    script_path <- file.path(spec_dir, script_path)
  }

  if (!file.exists(script_path))
    stop("Collector script not found: ", script_path)

  env <- new.env(parent = globalenv())
  source(script_path, local = env)

  if (!exists("collect", envir = env, inherits = FALSE) ||
      !is.function(env$collect))
    stop("Script '", basename(script_path),
         "' must define a collect(max_results, ...) function")

  env$collect(max_results = max_results)
}

# ── Shared HTTP helper ────────────────────────────────────────────────────────

#' @noRd
.http_fetch_xml <- function(url, params, retry_n = 3L) {
  req <- httr2::request(url) |>
    httr2::req_user_agent("cyberarxiv/0.1.0") |>
    httr2::req_retry(max_tries = retry_n, max_seconds = 30) |>
    httr2::req_timeout(seconds = 60)

  if (length(params) > 0L)
    req <- do.call(httr2::req_url_query, c(list(req), params))

  resp <- httr2::req_perform(req)

  if (httr2::resp_status(resp) != 200L)
    stop("HTTP ", httr2::resp_status(resp), " from ", url)

  xml2::read_xml(httr2::resp_body_raw(resp))
}

#' @noRd
.pagination_params <- function(pagination, start, n) {
  if (is.null(pagination)) return(list())
  ptype <- pagination$type %||% "none"
  if (ptype == "none") return(list())

  sp <- pagination$start_param %||% "start"
  np <- pagination$size_param  %||% "max_results"

  if (ptype == "offset") {
    p <- list(); p[[sp]] <- start; p[[np]] <- n; p
  } else if (ptype == "page") {
    ps   <- as.integer(pagination$page_size %||% n)
    page <- floor(start / ps) + 1L
    p <- list(); p[[sp]] <- page; p[[np]] <- ps; p
  } else {
    list()
  }
}

# ── Built-in transforms ───────────────────────────────────────────────────────

#' @noRd
.get_transform <- function(name) {
  list(
    strip_arxiv_id = function(x) {
      x <- sub("^.*/abs/", "", x)
      sub("v[0-9]+$", "", x)
    },
    map_arxiv_categories = function(x) {
      codes <- trimws(unlist(strsplit(x, ";", fixed = TRUE)))
      codes <- codes[nzchar(codes)]
      mapped <- unname(.arxiv_category_map[codes])
      mapped[is.na(mapped)] <- codes[is.na(mapped)]
      paste(mapped, collapse = ", ")
    },
    strip_html = function(x) {
      x <- gsub("<[^>]+>", " ", x)
      trimws(gsub("\\s+", " ", x))
    },
    identity = function(x) x
  )[[name]]
}

# ── Shared empty df ───────────────────────────────────────────────────────────

#' @noRd
.empty_feed_df <- function() {
  data.frame(
    id             = character(0),
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
