# Определяем корень проекта (где находится DESCRIPTION)
find_project_root <- function() {
  wd <- getwd()
  # Поднимаемся вверх по директориям, пока не найдем DESCRIPTION
  while (wd != "/" && !file.exists(file.path(wd, "DESCRIPTION"))) {
    wd <- dirname(wd)
  }
  if (file.exists(file.path(wd, "DESCRIPTION"))) {
    return(wd)
  }
  # Если не нашли, возвращаем текущую директорию
  return(getwd())
}

project_root <- find_project_root()

# Ищем исходный файл
rds_path <- NULL

inst_file <- file.path(project_root, "inst", "extdata", "arxiv_papers.rds")
raw_data_file <- file.path(project_root, "raw-data", "arxiv_papers.rds")

if (file.exists(inst_file)) {
  rds_path <- inst_file
} else if (file.exists(raw_data_file)) {
  rds_path <- raw_data_file
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

# Создаем директорию data/ в корне проекта (для встроенных датасетов пакета)
data_dir <- file.path(project_root, "data")
if (!dir.exists(data_dir)) {
  dir.create(data_dir, showWarnings = FALSE, recursive = TRUE)
}

# Сохраняем датасет в data/ для использования как встроенного датасета (как iris)
# После пересборки пакета будет доступен как cyberarxiv_dataset без вызова функций
save(cyberarxiv_dataset, file = file.path(data_dir, "cyberarxiv_dataset.rda"), compress = "bzip2")

