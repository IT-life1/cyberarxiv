#' Package startup helpers
#'
#' @name cyberarxiv-package
#' @import dplyr
#' @importFrom magrittr %>%
#' @importFrom stats setNames
#' @importFrom utils head tail
## Declare known global variables to satisfy R CMD check for dplyr pipelines
if (getRversion() >= "2.15.1") {
  utils::globalVariables(
    c("tag", "n", "abstract", "word", "authors",
      "published_month", "published_day", "published_weekday",
      "n_authors", "percentage", "ml_results", "ml_tag", "ml_confidence",
      "source", "language", "month", "year",
      "ingested_at", "published_date", "avg_conf", "isolate")
  )
}

NULL
