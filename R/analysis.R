#' @param data dataframe from load_raw_data()
#' @param query text to search
#' @param year year filter (optional)
#'
#' @return filtered dataframe
#' @export
search_papers <- function(data, query = NULL, year = NULL) {
  
  if (nrow(data) == 0) return(data)
  
  result <- data
  
  # search in title and abstract
  if (!is.null(query)) {
    query <- tolower(query)
    title_match <- grepl(query, tolower(data$title))
    abstract_match <- grepl(query, tolower(data$abstract))
    result <- data[title_match | abstract_match, ]
  }
  
  # filter by year
  if (!is.null(year)) {
    years <- as.integer(format(as.POSIXct(result$published_date), "%Y"))
    result <- result[years == year, ]
  }
  
  rownames(result) <- NULL
  result
}


#' @param data dataframe from load_raw_data()
#'
#' @return list with statistics
#' @export
analyze_papers <- function(data) {
  
  if (nrow(data) == 0) {
    return(list(total = 0))
  }
  
  total <- nrow(data)
  
  years <- as.integer(format(as.POSIXct(data$published_date), "%Y"))
  by_year <- as.data.frame(table(years))
  names(by_year) <- c("year", "count")
  
  cats <- unlist(strsplit(data$categories, ";"))
  cats <- trimws(cats)
  cat_table <- sort(table(cats), decreasing = TRUE)
  top_cats <- head(cat_table, 10)
  
  authors <- unlist(strsplit(data$authors, ";"))
  authors <- trimws(authors)
  author_table <- sort(table(authors), decreasing = TRUE)
  top_authors <- head(author_table, 10)
  
  list(
    total = total,
    by_year = by_year,
    top_categories = as.data.frame(top_cats),
    top_authors = as.data.frame(top_authors)
  )
}