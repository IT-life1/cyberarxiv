#' Package startup helpers
#'
#' @name cyberarxiv-package
#' @import dplyr
#' @importFrom magrittr %>%
## Declare known global variables to satisfy R CMD check for dplyr pipelines
if (getRversion() >= "2.15.1") {
  utils::globalVariables(
    c("tag", "n", "abstract", "word", "authors", "published_month", "published_weekday", "n_authors")
  )
}

NULL
