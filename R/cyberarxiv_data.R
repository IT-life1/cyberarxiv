#' CyberArXiv: Dataset of 1000 Recent AI/ML Research Papers
#'
#' A curated dataset of 1000 recent research papers from arXiv in the fields of 
#' Machine Learning, Artificial Intelligence, and related areas. Data is scraped 
#' from arXiv via the CyberArXiv API (or scraper) and includes metadata such as 
#' titles, authors, abstracts, categories, and publication dates.
#'
#' @format A data frame with 1000 rows and 10 variables:
#' \describe{
#'   \item{paper_id}{Character string. Unique identifier for the paper on arXiv (e.g., "2512.16917").}
#'   \item{link}{Character string. URL to the paper on arXiv.}
#'   \item{title}{Character string. Title of the paper.}
#'   \item{authors}{Character string. Comma-separated list of authors.}
#'   \item{abstract}{Character string. Abstract text of the paper.}
#'   \item{categories}{Character string. Main arXiv category (e.g., "Computer Science").}
#'   \item{published_date}{POSIXct. Date and time when the paper was first published on arXiv.}
#'   \item{updated_date}{POSIXct. Date and time of the last update (if any).}
#'   \item{ingested_at}{POSIXct. Timestamp when this record was ingested into the dataset.}
#'   \item{tag}{Character string. Primary topic tag assigned by CyberArXiv (e.g., "ML Methodology", "AI Ethics").}
#' }
#' @examples
#' # Load the dataset
#' data(cyberarxiv_data)
#' head(cyberarxiv_data)
#'
"cyberarxiv_data"