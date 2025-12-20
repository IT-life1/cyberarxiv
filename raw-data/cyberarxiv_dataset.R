rds_path <- NULL

if (file.exists(file.path("inst", "extdata", "arxiv_papers.rds"))) {
  rds_path <- file.path("inst", "extdata", "arxiv_papers.rds")
} else if (file.exists(file.path("raw-data", "arxiv_papers.rds"))) {
  rds_path <- file.path("raw-data", "arxiv_papers.rds")
}

if (!is.null(rds_path) && file.exists(rds_path)) {
  cyberarxiv_dataset <- readRDS(rds_path)
} else {
  # Если файла нет, создаем пустой датафрейм с правильной структурой
  cyberarxiv_dataset <- data.frame(
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

# Создаем директорию data/ если её нет (для встроенных датасетов пакета)
if (!dir.exists("data")) {
  dir.create("data", showWarnings = FALSE)
}

# Сохраняем датасет в data/ для использования как встроенного датасета (как iris)
# После пересборки пакета будет доступен как cyberarxiv_dataset без вызова функций
save(cyberarxiv_dataset, file = file.path("data", "cyberarxiv_dataset.rda"), compress = "bzip2")

