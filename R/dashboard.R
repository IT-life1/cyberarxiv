#' Render the cyberarxiv Quarto dashboard
#'
#' Рендерит Quarto-дашборд. Если source = NULL, используется встроенный шаблон
#' (лежит прямо в этом R-файле), без необходимости хранить inst/quarto/dashboard.qmd.
#'
#' @param source Path to a Quarto `.qmd` file. If NULL, uses embedded template.
#' @param output_dir Directory where the rendered HTML (dashboard.html) will be written.
#'   Defaults to `_site`.
#' @param open_browser Logical; if TRUE (default when interactive) opens result in a browser.
#' @param ... Additional arguments passed to `quarto::quarto_render()`.
#'
#' @return Invisibly returns the path to the rendered HTML file.
#' @export
render_dashboard <- function(source = NULL,
                             output_dir = "_site",
                             open_browser = interactive(),
                             ...) {
  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

  if (!requireNamespace("quarto", quietly = TRUE)) {
    stop("Package 'quarto' is required to render the Quarto dashboard.")
  }

  staging_root <- file.path(
    tempdir(),
    sprintf("cyberarxiv-dashboard-%s", as.integer(Sys.time()))
  )
  dir.create(staging_root, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(staging_root, recursive = TRUE, force = TRUE), add = TRUE)

  staging_dir <- file.path(staging_root, "src")
  dir.create(staging_dir, recursive = TRUE, showWarnings = FALSE)

  staged_source <- if (is.null(source)) {
    .materialize_embedded_dashboard(staging_dir)
  } else {
    if (!file.exists(source)) stop("Quarto dashboard source not found at ", source)
    source <- normalizePath(source, winslash = "/", mustWork = TRUE)
    file.copy(source, file.path(staging_dir, basename(source)), overwrite = TRUE)
    file.path(staging_dir, basename(source))
  }

  quarto::quarto_render(
    input       = staged_source,
    output_dir  = staging_dir,
    output_file = "dashboard.html",
    execute_dir = staging_dir,
    quiet       = TRUE,
    ...
  )

  rendered_file <- file.path(staging_dir, "dashboard.html")
  if (!file.exists(rendered_file)) {
    stop("Quarto render did not produce ", rendered_file)
  }

  output_file <- file.path(output_dir, "dashboard.html")
  file.copy(rendered_file, output_file, overwrite = TRUE)

  # ассеты обычно "dashboard_files" или "<input>_files"
  support_src <- file.path(staging_dir, "dashboard_files")
  if (!dir.exists(support_src)) {
    alt <- file.path(
      staging_dir,
      paste0(tools::file_path_sans_ext(basename(staged_source)), "_files")
    )
    if (dir.exists(alt)) support_src <- alt
  }

  if (dir.exists(support_src)) {
    support_dst <- file.path(output_dir, basename(support_src))
    if (dir.exists(support_dst)) unlink(support_dst, recursive = TRUE, force = TRUE)
    ok <- file.copy(support_src, output_dir, recursive = TRUE)
    if (!ok) stop("Failed to copy rendered dashboard assets from staging area")
  }

  output_file <- normalizePath(output_file, winslash = "/", mustWork = TRUE)
  if (open_browser && file.exists(output_file)) {
    utils::browseURL(output_file)
  }

  invisible(output_file)
}


#' @noRd
.materialize_embedded_dashboard <- function(target_dir) {
  qmd_path <- file.path(target_dir, "dashboard.qmd")
  writeLines(.dashboard_template_qmd(), qmd_path, useBytes = TRUE)
  qmd_path
}

#' @noRd
.dashboard_template_qmd <- function() {
  c(
    '---',
    'title: "Анализ публикаций arXiv"',
    'format: html',
    'execute:',
    '  echo: false',
    '  warning: false',
    '  message: false',
    '---',
    '',
    '```{r setup}',
    'suppressPackageStartupMessages({',
    '  library(cyberarxiv)',
    '  library(dplyr)',
    '  library(plotly)',
    '  library(lubridate)',
    '  library(tidytext)',
    '  library(tidyr)',
    '  library(stringr)',
    '  library(ggplot2)',
    '  library(RColorBrewer)',
    '})',
    '',
    '# Данные',
    'final_data <- cyberarxiv::load_publications()',
    'has_data <- nrow(final_data) > 0',
    '',
    'final_data <- final_data %>%',
    '  mutate(',
    '    published_month = floor_date(published_date, "day"),',
    '    published_weekday = wday(published_date, label = TRUE, abbr = TRUE)',
    '  )',
    '',
    'authors_long <- final_data %>%',
    '  select(paper_id, authors) %>%',
    '  filter(!is.na(authors)) %>%',
    '  mutate(authors = str_split(authors, ",\\\\s*")) %>%',
    '  unnest(authors) %>%',
    '  mutate(authors = str_trim(authors))',
    '',
    'pubs_by_month <- final_data %>% count(published_month) %>% arrange(published_month)',
    'top_authors <- authors_long %>% count(authors, sort = TRUE) %>% head(10)',
    'tag_counts <- final_data %>% filter(!is.na(tag)) %>% count(tag, sort = TRUE)',
    '',
    'weekday_labels <- c("Mon"="Пн","Tue"="Вт","Wed"="Ср","Thu"="Чт","Fri"="Пт","Sat"="Сб","Sun"="Вс")',
    'pubs_by_weekday <- final_data %>%',
    '  filter(!is.na(published_weekday)) %>%',
    '  count(published_weekday) %>%',
    '  mutate(',
    '    published_weekday = factor(',
    '      weekday_labels[as.character(published_weekday)],',
    '      levels = unname(weekday_labels)',
    '    )',
    '  )',
    '',
    'author_counts <- final_data %>%',
    '  filter(!is.na(authors)) %>%',
    '  mutate(n_authors = str_count(authors, ",") + 1)',
    '',
    'top30 <- cyberarxiv::get_top_words(final_data, n = 30)',
    'topic_words <- cyberarxiv::get_top_words_by_tag(final_data, n = 5)',
    '```',
    '',
    '```{r data-note, echo=FALSE}',
    'if (!has_data) {',
    '  cat("<div class=\\"alert alert-warning\\">Нет локальных данных (load_publications() вернул 0 строк). Запусти ETL/обновление базы.</div>")',
    '}',
    '```',
    '',
    '## Кол-во публикаций по дням',
    '',
    '```{r publ-by-day, echo=FALSE}',
    'plot_ly(',
    '  pubs_by_month,',
    '  x = ~published_month,',
    '  y = ~n,',
    '  type = "scatter",',
    '  mode = "lines+markers",',
    '  line = list(color = "#9467bd", width = 2),',
    '  marker = list(size = 6, color = "#9467bd")',
    ') %>%',
    '  layout(',
    '    xaxis = list(title = "День"),',
    '    yaxis = list(title = "Количество публикаций")',
    '  )',
    '```',
    '',
    '## Авторы с наибольшим кол-вом публикаций',
    '',
    '```{r authors-populars, echo=FALSE}',
    'plot_ly(',
    '  top_authors,',
    '  x = ~reorder(authors, n),',
    '  y = ~n,',
    '  type = "bar",',
    '  marker = list(color = "#2ca02c")',
    ') %>%',
    '  layout(',
    '    xaxis = list(tickangle = -45, title = ""),',
    '    yaxis = list(title = "Число публикаций")',
    '  )',
    '```',
    '',
    '## Процентное соотношение публикаций с метками',
    '',
    '```{r tags-percentage, echo=FALSE}',
    'plot_ly(',
    '  tag_counts,',
    '  labels = ~tag,',
    '  values = ~n,',
    '  type = "pie",',
    '  textinfo = "label+percent",',
    '  textposition = "inside",',
    '  marker = list(colors = RColorBrewer::brewer.pal(12, "Set3"))',
    ') %>%',
    '  layout(',
    '    title = list(text = "Распределение публикаций по тематическим меткам", x = 0.5),',
    '    showlegend = TRUE',
    '  )',
    '```',
    '',
    '## Число публикаций по дням недели',
    '',
    '```{r publications-by-weekday, echo=FALSE}',
    'plot_ly(',
    '  pubs_by_weekday,',
    '  x = ~published_weekday,',
    '  y = ~n,',
    '  type = "bar",',
    '  marker = list(color = "#9467bd")',
    ') %>%',
    '  layout(',
    '    xaxis = list(title = "День недели"),',
    '    yaxis = list(title = "Количество")',
    '  )',
    '```',
    '',
    '## Самые частые слова в аннотациях',
    '',
    '```{r top-words-all, echo=FALSE}',
    'plot_ly(',
    '  top30,',
    '  x = ~reorder(word, n),',
    '  y = ~n,',
    '  type = "bar",',
    '  marker = list(color = "#2ca02c")',
    ') %>%',
    '  layout(',
    '    xaxis = list(title = "", tickangle = -45),',
    '    yaxis = list(title = "Частота")',
    '  )',
    '```',
    '',
    '## Распределение числа авторов в публикациях',
    '',
    '```{r amounts-of-authors, echo=FALSE}',
    'plot_ly(',
    '  author_counts,',
    '  x = ~n_authors,',
    '  type = "histogram",',
    '  marker = list(color = "#9467bd")',
    ') %>%',
    '  layout(',
    '    xaxis = list(title = "Число авторов"),',
    '    yaxis = list(title = "Число публикаций")',
    '  )',
    '```',
    '',
    '## Топ-5 ключевых слов по темам',
    '',
    '```{r top-words-by-tag, echo=FALSE}',
    'if (nrow(topic_words) == 0) {',
    '  plot_ly() %>% layout(title = "Недостаточно данных для визуализации")',
    '} else {',
    '  topic_words <- topic_words %>%',
    '    arrange(tag, desc(n)) %>%',
    '    mutate(word = tidytext::reorder_within(word, n, tag))',
    '',
    '  p <- ggplot(topic_words, aes(x = n, y = word, fill = tag)) +',
    '    geom_col(show.legend = FALSE) +',
    '    facet_wrap(~ tag, scales = "free_y", ncol = 4) +',
    '    tidytext::scale_y_reordered() +',
    '    labs(x = "Частота", y = "Ключевое слово") +',
    '    theme_minimal()',
    '',
    '  ggplotly(p)',
    '}',
    '```'
  )
}
