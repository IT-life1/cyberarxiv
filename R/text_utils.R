#' Unified custom stopwords for text processing
#'
#' FIX: Single source of truth for stopwords, used by both get_top_words and get_top_words_by_tag.
#' Previously duplicated across classify_data.R and text_utils.R with inconsistencies.
#'
#' @noRd
.custom_stopwords_unified <- function() {
  c(
    "model", "paper", "data", "result", "results", "method", "methods", "system", "systems",
    "work", "works", "study", "studies", "research", "approach", "approaches", "framework",
    "frameworks", "technique", "techniques", "algorithm", "algorithms", "solution", "solutions",
    "show", "shows", "shown", "demonstrate", "demonstrates", "demonstrated", "present", "presents",
    "presented", "propose", "proposes", "proposed", "introduce", "introduces", "introduced",
    "develop", "develops", "developed", "design", "designs", "designed", "build", "builds", "built",
    "use", "uses", "used", "utilize", "utilizes", "utilized", "employ", "employs", "employed",
    "also", "can", "could", "would", "will", "may", "might", "should", "shall", "must",
    "one", "two", "first", "second", "third", "finally", "further", "furthermore", "moreover",
    "however", "nevertheless", "although", "though", "even", "just", "only", "simply", "very",
    "new", "novel", "efficient", "effective", "robust", "scalable", "flexible", "practical",
    "significant", "significantly", "important", "key", "main", "major", "minor", "better",
    "best", "improve", "improves", "improved", "enhance", "enhances", "enhanced", "achieve",
    "achieves", "achieved", "performance", "accuracy", "precision", "recall", "f1", "auc",
    "compare", "compares", "compared", "comparison", "baseline", "baselines", "experiment",
    "experiments", "experimental", "evaluation", "evaluations", "evaluate", "evaluates",
    "evaluated", "dataset", "datasets", "training", "train", "trains", "trained", "test",
    "tests", "tested", "validation", "validate", "validates", "validated", "sota", "state",
    "art", "existing", "previous", "prior", "current", "traditional", "conventional",
    "based", "using", "via", "through", "within", "without", "across", "between", "among",
    "under", "over", "during", "after", "before", "since", "thus", "hence", "therefore",
    "consequently", "additionally", "specifically", "particularly", "generally", "typically",
    "commonly", "widely", "highly", "recently", "previously", "finally", "et", "al", "e.g",
    "i.e", "fig", "figure", "table", "section", "chapter", "page", "author", "authors",
    "article", "articles", "publication", "publications", "literature", "review", "survey",
    "arxiv", "preprint", "submission", "manuscript", "code", "implementation", "available",
    "github", "repository", "open", "source", "download", "access", "http", "https", "org",
    "real", "tasks", "multi"
  )
}

#' Extract top-N words from abstracts
#'
#' Processes abstracts: cleaning, tokenization, stop-word filtering,
#' and returns top words.
#'
#' @param data data.frame with column `abstract`
#' @param n integer, how many top words to return (default 30)
#' @return tibble with columns `word`, `n`
#' @export
get_top_words <- function(data, n = 30) {
  if (!"abstract" %in% names(data)) {
    stop("Column 'abstract' is required")
  }

  custom_stopwords <- .custom_stopwords_unified()

  top_words <- data %>%
    dplyr::filter(!is.na(abstract)) %>%
    dplyr::select(abstract) %>%
    dplyr::mutate(
      abstract = tolower(abstract),
      abstract = stringr::str_remove_all(abstract, "<.*?>"),
      abstract = stringr::str_replace_all(abstract, "[^[:alnum:]\\s]", " "),
      abstract = stringr::str_squish(abstract)
    ) %>%
    tidytext::unnest_tokens(word, abstract) %>%
    dplyr::filter(stringr::str_detect(word, "^[a-z]{3,}$")) %>%
    dplyr::anti_join(tidytext::get_stopwords(source = "snowball"), by = "word") %>%
    dplyr::anti_join(tibble::tibble(word = custom_stopwords), by = "word") %>%
    dplyr::count(word, sort = TRUE) %>%
    head(n)

  return(top_words)
}


#' Get top-N words per topic
#'
#' @param data data.frame with columns `abstract` and `tag`
#' @param n integer, number of words per topic
#' @return tibble with columns `tag`, `word`, `n`
#' @export
get_top_words_by_tag <- function(data, n = 5) {
  if (!"abstract" %in% names(data) || !"tag" %in% names(data)) {
    stop("Columns 'abstract' and 'tag' are required")
  }

  custom_stopwords <- .custom_stopwords_unified()

  result <- data %>%
    dplyr::filter(!is.na(abstract) & !is.na(tag) & tag != "other") %>%
    dplyr::select(tag, abstract) %>%
    dplyr::mutate(
      abstract = tolower(abstract),
      abstract = stringr::str_remove_all(abstract, "<.*?>"),
      abstract = stringr::str_replace_all(abstract, "[^[:alnum:]\\s]", " "),
      abstract = stringr::str_squish(abstract)
    ) %>%
    tidytext::unnest_tokens(word, abstract) %>%
    dplyr::filter(stringr::str_detect(word, "^[a-z]{3,}$")) %>%
    dplyr::anti_join(tidytext::get_stopwords(source = "snowball"), by = "word") %>%
    dplyr::anti_join(tibble::tibble(word = custom_stopwords), by = "word") %>%
    dplyr::count(tag, word, sort = TRUE) %>%
    dplyr::group_by(tag) %>%
    dplyr::slice_head(n = n) %>%
    dplyr::ungroup()

  return(result)
}
