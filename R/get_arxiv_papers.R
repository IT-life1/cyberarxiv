#' Get arXiv papers metadata
#'
#' Fetches papers from arXiv API (Atom) and returns a data.frame.
#'
#' @param query arXiv search query. If NULL, uses a broad cybersecurity filter.
#' @param max_results How many papers to return (integer).
#'
#' @return data.frame with columns:
#'   id, source, language, link, title, authors, abstract, categories,
#'   published_date, updated_date, tag.
#' @export
get_arxiv_papers <- function(query = NULL, max_results = 100) {
  if (is.null(query)) {
    # FIX: Dynamic date range instead of hardcoded 202512312359
    now_str <- format(Sys.time(), "%Y%m%d%H%M", tz = "UTC")
    query <- paste0(
      "(cat:cs.CR OR cat:cs.NI OR cat:cs.LG) ",
      "AND all:(malware OR intrusion OR attack OR threat OR adversary ",
      "OR botnet OR exploit OR trojan OR phishing) ",
      "AND submittedDate:[202001010000 TO ", now_str, "]"
    )
  }

  max_results <- as.integer(max_results)
  if (is.na(max_results) || max_results < 1L) return(.empty_df())

  out <- list()
  start <- 0L
  seen_ids <- character(0)  # FIX: track seen IDs to prevent duplicates across pages

  while (start < max_results) {
    n <- min(100L, max_results - start)

    # FIX: Added retry logic with error handling
    doc <- tryCatch(
      .fetch_arxiv_xml(query, start, n),
      error = function(e) {
        warning("arXiv API request failed at start=", start, ": ", conditionMessage(e))
        NULL
      }
    )
    if (is.null(doc)) break

    df <- tryCatch(
      .parse_atom(doc),
      error = function(e) {
        warning("Failed to parse arXiv response at start=", start, ": ", conditionMessage(e))
        .empty_df()
      }
    )

    if (nrow(df) == 0L) break

    # FIX: Deduplicate across pages
    df <- df[!df$id %in% seen_ids, , drop = FALSE]
    if (nrow(df) == 0L) break  # all results were duplicates

    seen_ids <- c(seen_ids, df$id)
    out[[length(out) + 1L]] <- df
    start <- start + nrow(df)

    Sys.sleep(0.3)  # FIX: slightly longer delay to be nice to arXiv API
  }

  if (length(out) == 0L) return(.empty_df())

  res <- do.call(rbind, out)
  rownames(res) <- NULL
  res
}

#' @noRd
.fetch_arxiv_xml <- function(query, start, max_results) {
  resp <- httr2::request("https://export.arxiv.org/api/query") |>
    httr2::req_url_query(
      search_query = query,
      start = start,
      max_results = max_results,
      sortBy = "submittedDate",
      sortOrder = "descending"
    ) |>
    httr2::req_user_agent("cyberarxiv/0.0.1") |>
    httr2::req_retry(max_tries = 3, max_seconds = 30) |>  # FIX: retry on transient failures
    httr2::req_timeout(seconds = 60) |>  # FIX: explicit timeout
    httr2::req_perform()

  # FIX: check HTTP status
  if (httr2::resp_status(resp) != 200) {
    stop("arXiv API returned HTTP ", httr2::resp_status(resp))
  }

  xml2::read_xml(httr2::resp_body_raw(resp))
}

#' @noRd
.parse_atom <- function(doc) {
  ns <- c(atom = "http://www.w3.org/2005/Atom")

  e <- xml2::xml_find_all(doc, ".//atom:entry", ns)
  if (!length(e)) return(.empty_df())

  txt1 <- function(x, p) trimws(xml2::xml_text(xml2::xml_find_first(x, p, ns)))

  links <- vapply(e, txt1, "", "./atom:id")
  ids <- sub("^.*/abs/", "", links)
  ids <- sub("v[0-9]+$", "", ids)

  data.frame(
    id = ids,
    source = "arxiv",
    language = "en",
    link = links,
    title = vapply(e, txt1, "", "./atom:title"),
    authors = vapply(e, function(x) {
      a <- xml2::xml_find_all(x, "./atom:author/atom:name", ns)
      paste(trimws(xml2::xml_text(a)), collapse = "; ")
    }, ""),
    abstract = vapply(e, txt1, "", "./atom:summary"),
    categories = vapply(e, function(x) {
      c1 <- xml2::xml_find_all(x, "./atom:category", ns)
      paste(xml2::xml_attr(c1, "term"), collapse = "; ")
    }, ""),
    published_date = vapply(e, txt1, "", "./atom:published"),
    updated_date = vapply(e, txt1, "", "./atom:updated"),
    tag = "",
    stringsAsFactors = FALSE
  )
}

#' @noRd
.empty_df <- function() {
  data.frame(
    id = character(0),
    source = character(0),
    language = character(0),
    link = character(0),
    title = character(0),
    authors = character(0),
    abstract = character(0),
    categories = character(0),
    published_date = character(0),
    updated_date = character(0),
    tag = character(0),
    stringsAsFactors = FALSE
  )
}
