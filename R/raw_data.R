#' Save arXiv publications to RDS
#' 
#' Сохраняет данные в файл. Определяет корень проекта по наличию DESCRIPTION
#' и сохраняет в правильную директорию относительно корня проекта.
#' 
#' @param data A data.frame to save
#' @param filename Name of the RDS file (default: "arxiv_papers.rds")
#' @param dir Directory to save the file (default: "raw-data")
#'
#' @return Invisibly returns a list with path, number of rows, and file size
#' @export
#'
#' @examples
#' \dontrun{
#' papers <- get_arxiv_papers(max_results = 50)
#' save_raw_data(papers)
#' save_raw_data(papers, filename = "my_papers.rds")
#' }
save_raw_data <- function(data, filename = "arxiv_papers.rds", dir = "raw-data") {
  if (!is.data.frame(data)) {
    stop("'data' must be a data.frame")
  }
  
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
  target_dir <- file.path(project_root, dir)
  
  if (!dir.exists(target_dir)) {
    dir.create(target_dir, recursive = TRUE, showWarnings = FALSE)
  }
  
  filepath <- file.path(target_dir, filename)
  
  saveRDS(data, file = filepath)
  
  invisible(list(
    path = filepath,
    rows = nrow(data),
    size_bytes = file.size(filepath)
  ))
}

#' Load publications from local RDS storage
#' 
#' Загружает сырые данные из файла. Ищет файл в пакете (`inst/extdata/`),
#' затем в локальной директории.
#'
#' @param filename Name of the RDS file to load (default: "arxiv_papers.rds")
#' @param dir Directory containing the file (default: "raw-data")
#'
#' @return A data.frame loaded from the RDS file, or an empty data.frame if file not found
#' @export
#'
#' @examples
#' \dontrun{
#' papers <- load_raw_data()
#' papers <- load_raw_data(filename = "my_papers.rds")
#' }
load_raw_data <- function(filename = "arxiv_papers.rds", dir = "raw-data") {
  # 1. Пробуем загрузить из inst/extdata/ пакета (встроенный файл)
  # system.file() работает независимо от рабочей директории пользователя
  pkg_file <- system.file("extdata", filename, package = "cyberarxiv")
  if (nzchar(pkg_file) && file.exists(pkg_file)) {
    return(readRDS(pkg_file))
  }
  
  # 2. Пробуем локальный файл в рабочей директории
  local_file <- file.path(dir, filename)
  if (file.exists(local_file)) {
    return(readRDS(local_file))
  }
  
  # 3. Если ничего не найдено, возвращаем пустой датафрейм без предупреждения
  # (чтобы не было ошибок, просто возвращаем пустой датафрейм)
  return(data.frame(
    id = character(0),
    link = character(0),
    title = character(0),
    authors = character(0),
    abstract = character(0),
    categories = character(0),
    published_date = character(0),
    updated_date = character(0),
    stringsAsFactors = FALSE
  ))
}