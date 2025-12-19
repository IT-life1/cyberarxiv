#' Render the cyberarxiv Quarto dashboard
#'
#' Рендерит Quarto-дашборд. Если source = NULL, используется встроенный шаблон
#' (лежит прямо в этом R-файле), без необходимости хранить inst/quarto/dashboard.qmd.
#'
#' @param source Path to a Quarto `.qmd` file. If NULL, uses embedded template.
#' @param output_dir Directory where the rendered HTML (dashboard.html) will be written.
#'   Defaults to `_site`.
#' @param quiet Logical; passed through to `quarto::quarto_render()` for verbose output.
#' @param ... Additional arguments passed to `quarto::quarto_render()`.
#'
#' @export
render_dashboard <- function(source = NULL,
                             output_dir = "_site",
                             quiet = TRUE,
                             ...) {
  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)
  if (!dir.exists(output_dir)) {
    stop("Failed to create output_dir at ", output_dir)
  }

  if (!requireNamespace("quarto", quietly = TRUE)) {
    stop("Package 'quarto' is required to render the Quarto dashboard.")
  }

  dashboard_ctx <- .prepare_dashboard_context()

  staging_root <- file.path(
    tempdir(),
    sprintf("cyberarxiv-dashboard-%s", as.integer(Sys.time()))
  )
  dir.create(staging_root, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(staging_root, recursive = TRUE, force = TRUE), add = TRUE)

  staging_dir <- file.path(staging_root, "src")
  dir.create(staging_dir, recursive = TRUE, showWarnings = FALSE)
  saveRDS(dashboard_ctx, file.path(staging_dir, "dashboard-data.rds"))

  staged_source <- if (is.null(source)) {
    .materialize_embedded_dashboard(staging_dir)
  } else {
    if (!file.exists(source)) stop("Quarto dashboard source not found at ", source)
    source <- normalizePath(source, winslash = "/", mustWork = TRUE)
    file.copy(source, file.path(staging_dir, basename(source)), overwrite = TRUE)
    file.path(staging_dir, basename(source))
  }

  old_dir <- getwd()
  on.exit(setwd(old_dir), add = TRUE)
  setwd(staging_dir)

  quarto::quarto_render(
    input = basename(staged_source),
    output_file = "dashboard.html",
    execute_dir = staging_dir,
    quiet = quiet,
    ...
  )

  rendered_html <- file.path(staging_dir, "dashboard.html")
  if (!file.exists(rendered_html)) {
    stop("Quarto render did not create dashboard.html")
  }

  destination_html <- file.path(output_dir, "dashboard.html")
  if (!isTRUE(file.copy(rendered_html, destination_html, overwrite = TRUE))) {
    stop("Unable to copy rendered dashboard to ", destination_html)
  }

  rendered_assets <- sub("\\.html$", "_files", rendered_html)
  if (dir.exists(rendered_assets)) {
    destination_assets <- file.path(output_dir, basename(rendered_assets))
    if (dir.exists(destination_assets)) {
      unlink(destination_assets, recursive = TRUE, force = TRUE)
    }
    dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
    file.copy(rendered_assets, output_dir, recursive = TRUE, overwrite = TRUE)
  }

  invisible(destination_html)
}

#' @noRd
.prepare_dashboard_context <- function() {
  final_data <- load_publications()
  has_data <- nrow(final_data) > 0

  final_aug <- final_data %>%
    mutate(
      published_month = lubridate::floor_date(published_date, "day"),
      published_weekday = lubridate::wday(published_date, label = TRUE, abbr = TRUE)
    )

  authors_long <- final_aug %>%
    select(paper_id, authors) %>%
    filter(!is.na(authors)) %>%
    mutate(authors = stringr::str_split(authors, ",\\s*")) %>%
    tidyr::unnest(authors) %>%
    mutate(authors = stringr::str_trim(authors))

  pubs_by_month <- final_aug %>%
    count(published_month) %>%
    arrange(published_month)

  top_authors <- authors_long %>%
    count(authors, sort = TRUE) %>%
    head(10)

  tag_counts <- final_aug %>%
    filter(!is.na(tag)) %>%
    count(tag, sort = TRUE)

  weekday_map <- c(
    Mon = "Пн", Tue = "Вт", Wed = "Ср",
    Thu = "Чт", Fri = "Пт", Sat = "Сб", Sun = "Вс"
  )

  pubs_by_weekday <- final_aug %>%
    filter(!is.na(published_weekday)) %>%
    mutate(
      published_weekday = factor(
        weekday_map[as.character(published_weekday)],
        levels = unname(weekday_map)
      )
    ) %>%
    count(published_weekday)

  author_counts <- final_aug %>%
    filter(!is.na(authors)) %>%
    mutate(n_authors = stringr::str_count(authors, ",") + 1)

  top_words <- get_top_words(final_data, n = 30)
  topic_words <- get_top_words_by_tag(final_data, n = 5)

  list(
    has_data = has_data,
    pubs_by_month = pubs_by_month,
    top_authors = top_authors,
    tag_counts = tag_counts,
    pubs_by_weekday = pubs_by_weekday,
    author_counts = author_counts,
    top_words = top_words,
    topic_words = topic_words
  )
}

#' @noRd
.materialize_embedded_dashboard <- function(dest_dir) {
  template_path <- file.path(dest_dir, "dashboard.qmd")
  writeLines(.embedded_dashboard_template(), template_path, useBytes = TRUE)
  template_path
}

#' @noRd
.embedded_dashboard_template <- function() {
  c(
    "---",
    "title: \"Анализ публикаций arXiv\"",
    "format: html",
    "execute:",
    "  echo: false",
    "  warning: false",
    "  message: false",
    "---",
    "",
    "```{r setup}",
    "suppressPackageStartupMessages({",
    "  library(dplyr)",
    "  library(plotly)",
    "  library(ggplot2)",
    "  library(RColorBrewer)",
    "  library(tidytext)",
    "})",
    "",
    "ctx <- readRDS(\"dashboard-data.rds\")",
    "has_data <- ctx$has_data",
    "pubs_by_month <- ctx$pubs_by_month",
    "top_authors <- ctx$top_authors",
    "tag_counts <- ctx$tag_counts",
    "pubs_by_weekday <- ctx$pubs_by_weekday",
    "author_counts <- ctx$author_counts",
    "top30 <- ctx$top_words",
    "topic_words <- ctx$topic_words",
    "```",
    "",
    "```{r data-note, echo=FALSE}",
    "if (!has_data) {",
    "  cat(\"<div class=\\\"alert alert-warning\\\">Нет локальных данных (load_publications() вернул 0 строк). Запусти ETL/обновление базы.</div>\")",
    "}",
    "```",
    "",
    "## Кол-во публикаций по дням",
    "",
    "```{r publ-by-day, echo=FALSE}",
    "plot_ly(",
    "  pubs_by_month,",
    "  x = ~published_month,",
    "  y = ~n,",
    "  type = \"scatter\",",
    "  mode = \"lines+markers\",",
    "  line = list(color = \"#9467bd\", width = 2),",
    "  marker = list(size = 6, color = \"#9467bd\")",
    ") %>%",
    "  layout(",
    "    xaxis = list(title = \"Месяц\"),",
    "    yaxis = list(title = \"Количество публикаций\")",
    "  )",
    "```",
    "",
    "## Авторы с наибольшим кол-вом публикаций",
    "",
    "```{r authors-populars, echo=FALSE}",
    "plot_ly(",
    "  top_authors,",
    "  x = ~reorder(authors, n),",
    "  y = ~n,",
    "  type = \"bar\",",
    "  marker = list(color = \"#2ca02c\")",
    ") %>%",
    "  layout(",
    "    xaxis = list(tickangle = -45, title = \"\"),",
    "    yaxis = list(title = \"Число публикаций\")",
    "  )",
    "```",
    "",
    "## Процентное соотношение публикаций с метками",
    "",
    "```{r tags-percentage, echo=FALSE}",
    "plot_ly(",
    "  tag_counts,",
    "  labels = ~tag,",
    "  values = ~n,",
    "  type = \"pie\",",
    "  textinfo = \"label+percent\",",
    "  textposition = \"inside\",",
    "  marker = list(colors = RColorBrewer::brewer.pal(12, \"Set3\"))",
    ") %>%",
    "  layout(",
    "    title = list(text = \"Распределение публикаций по тематическим меткам\", x = 0.5),",
    "    showlegend = TRUE",
    "  )",
    "```",
    "",
    "## Число публикаций по дням недели",
    "",
    "```{r publications-by-weekday, echo=FALSE}",
    "plot_ly(",
    "  pubs_by_weekday,",
    "  x = ~published_weekday,",
    "  y = ~n,",
    "  type = \"bar\",",
    "  marker = list(color = \"#9467bd\")",
    ") %>%",
    "  layout(",
    "    xaxis = list(title = \"День недели\"),",
    "    yaxis = list(title = \"Количество\")",
    "  )",
    "```",
    "",
    "## Самые частые слова в аннотациях",
    "",
    "```{r top-words-all, echo=FALSE}",
    "plot_ly(",
    "  top30,",
    "  x = ~reorder(word, n),",
    "  y = ~n,",
    "  type = \"bar\",",
    "  marker = list(color = \"#2ca02c\")",
    ") %>%",
    "  layout(",
    "    xaxis = list(title = \"\", tickangle = -45),",
    "    yaxis = list(title = \"Частота\")",
    "  )",
    "```",
    "",
    "## Распределение числа авторов в публикациях",
    "",
    "```{r amounts-of-authors, echo=FALSE}",
    "plot_ly(",
    "  author_counts,",
    "  x = ~n_authors,",
    "  type = \"histogram\",",
    "  marker = list(color = \"#9467bd\")",
    ") %>%",
    "  layout(",
    "    xaxis = list(title = \"Число авторов\"),",
    "    yaxis = list(title = \"Число публикаций\")",
    "  )",
    "```",
    "",
    "## Топ-5 ключевых слов по темам",
    "",
    "```{r top-words-by-tag, echo=FALSE}",
    "if (nrow(topic_words) == 0) {",
    "  plot_ly() %>% layout(title = \"Недостаточно данных для визуализации\")",
    "} else {",
    "  topic_words <- topic_words %>%",
    "    arrange(tag, desc(n)) %>%",
    "    mutate(word = tidytext::reorder_within(word, n, tag))",
    "",
    "  p <- ggplot(topic_words, aes(x = n, y = word, fill = tag)) +",
    "    geom_col(show.legend = FALSE) +",
    "    facet_wrap(~ tag, scales = \"free_y\", ncol = 4) +",
    "    tidytext::scale_y_reordered() +",
    "    labs(x = \"Частота\", y = \"Ключевое слово\") +",
    "    theme_minimal()",
    "",
    "  ggplotly(p)",
    "}",
    "```"
  )
}
