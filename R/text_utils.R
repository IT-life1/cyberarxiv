#' Извлечь топ-N слов из аннотаций
#'
#' Обрабатывает аннотации: очистка, токенизация, фильтрация стоп-слов,
#' и возвращает топ слов.
#'
#' @param data data.frame с колонкой `abstract`
#' @param n integer, сколько топ-слов вернуть (по умолчанию 30)
#' @return tibble с колонками `word`, `n`
#' @export
get_top_words <- function(data, n = 30) {
  if (!"abstract" %in% names(data)) {
    stop("Ожидается колонка 'abstract'")
  }

  custom_stopwords <- c(
    "model", "paper", "data", "result", "results", "method", "methods", "system", "systems",
    "work", "works", "study", "studies", "research", "approach", "approaches", "framework",
    # "frameworks", "technique", "techniques", "algorithm", "algorithms", "solution", "solutions",
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
    "achieves", "achieved", "performance",
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
  
  top_words <- data %>%
    dplyr::filter(!is.na(abstract)) %>%
    select(abstract) %>%
    mutate(
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


#' Получить топ-N слов по каждой теме
#'
#' @param data data.frame с колонками `abstract` и `tag`
#' @param n integer, сколько слов на тему
#' @return tibble с колонками `tag`, `word`, `n`
#' @export
get_top_words_by_tag <- function(data, n = 5) {
  if (!"abstract" %in% names(data) || !"tag" %in% names(data)) {
    stop("Требуются колонки 'abstract' и 'tag'")
  }
  
  custom_stopwords <- c(
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
    "github", "repository", "open", "source", "download", "access", "http", "https", "org"
  )
  
  result <- data %>%
    dplyr::filter(!is.na(abstract) & !is.na(tag) & tag != "other") %>%
    select(tag, abstract) %>%
    mutate(
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