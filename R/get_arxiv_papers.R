#' Get arXiv papers metadata
#'
#' Fetches papers from arXiv API (Atom) and returns a data.frame.
#'
#' @param query arXiv search query. If NULL, uses a broad cybersecurity filter.
#' @param max_results how many papers to return.
#'
#' @return data.frame with columns:
#'   id, link, title, authors, abstract, categories,
#'   published_date, updated_date.
#'
#' @export
get_arxiv_papers <- function(query = NULL, max_results = 100) {
  if (is.null(query)) {
    query <- paste0(
      "(cat:cs.CR OR cat:cs.NI OR cat:cs.LG) ",
      "AND all:(malware OR intrusion OR attack OR threat OR adversary ",
      "OR botnet OR exploit OR trojan OR phishing) ",
      "AND submittedDate:[202001010000 TO 202512312359]"
    )
  }

  max_results <- as.integer(max_results)

  out <- list()
  start <- 0L

  while (start < max_results) {
    n <- min(100L, max_results - start)

    doc <- .fetch_arxiv_xml(query, start, n)
    df <- .parse_atom(doc)

    if (nrow(df) == 0L) break

    out[[length(out) + 1L]] <- df
    start <- start + nrow(df)
  }

  if (length(out) == 0L) return(.empty_df())

  res <- do.call(rbind, out)
  rownames(res) <- NULL
  res
}

.fetch_arxiv_xml <- function(query, start, max_results) {
  resp <- httr2::request("https://export.arxiv.org/api/query") |>
    httr2::req_url_query(
      search_query = query,
      start = start,
      max_results = max_results
    ) |>
    httr2::req_user_agent("cyberarxiv/0.0.1") |>
    httr2::req_perform()

  xml2::read_xml(httr2::resp_body_raw(resp))
}

.parse_atom <- function(doc) {
  ns <- c(atom = "http://www.w3.org/2005/Atom")

  e <- xml2::xml_find_all(doc, ".//atom:entry", ns)
  if (!length(e)) return(.empty_df())

  txt1 <- function(x, p)
    trimws(xml2::xml_text(xml2::xml_find_first(x, p, ns)))

  links <- vapply(e, txt1, "", "./atom:id")
  ids <- sub("^.*/abs/", "", links)
  ids <- sub("v[0-9]+$", "", ids)

  data.frame(
    id = ids,
    link = links,
    title = vapply(e, txt1, "", "./atom:title"),
    authors = vapply(e, function(x)
      paste(
        trimws(xml2::xml_text(
          xml2::xml_find_all(x, "./atom:author/atom:name", ns)
        )),
        collapse = "; "
      ), ""),
    abstract = vapply(e, txt1, "", "./atom:summary"),
    categories = vapply(e, function(x)
      paste(
        xml2::xml_attr(
          xml2::xml_find_all(x, "./atom:category", ns),
          "term"
        ),
        collapse = "; "
      ), ""),
    published_date = vapply(e, txt1, "", "./atom:published"),
    updated_date = vapply(e, txt1, "", "./atom:updated"),
    stringsAsFactors = FALSE
  )
}

.empty_df <- function() {
  data.frame(
    id = character(0),
    link = character(0),
    title = character(0),
    authors = character(0),
    abstract = character(0),
    categories = character(0),
    published_date = character(0),
    updated_date = character(0),
    stringsAsFactors = FALSE
  )
}
