make_papers <- function() {
  data.frame(
    id = c("p1", "p2", "p3"),
    title = c("Ransomware in IoT", "TLS handshake analysis", "Phishing detection"),
    abstract = c(
      "We study ransomware infections on embedded devices.",
      "Cryptographic protocol analysis of modern TLS.",
      "Machine learning for phishing email detection."
    ),
    published_date = c("2023-04-01 12:00:00",
                       "2024-09-15 09:30:00",
                       "2024-01-20 18:45:00"),
    stringsAsFactors = FALSE
  )
}

test_that("search_papers returns input unchanged when no filters are supplied", {
  df <- make_papers()
  expect_equal(search_papers(df), df, ignore_attr = "row.names")
})

test_that("search_papers filters by query against title and abstract", {
  df <- make_papers()
  hits <- search_papers(df, query = "phishing")
  expect_equal(nrow(hits), 1L)
  expect_equal(hits$id, "p3")

  hits <- search_papers(df, query = "ransomware")
  expect_equal(hits$id, "p1")
})

test_that("search_papers query is case-insensitive", {
  df <- make_papers()
  expect_equal(search_papers(df, query = "RANSOMWARE")$id, "p1")
  expect_equal(search_papers(df, query = "Phishing")$id, "p3")
})

test_that("search_papers filters by year using published_date", {
  df <- make_papers()
  hits_2024 <- search_papers(df, year = 2024)
  expect_setequal(hits_2024$id, c("p2", "p3"))

  hits_2023 <- search_papers(df, year = 2023)
  expect_equal(hits_2023$id, "p1")
})

test_that("search_papers combines query and year filters", {
  df <- make_papers()
  hits <- search_papers(df, query = "phishing", year = 2024)
  expect_equal(hits$id, "p3")

  hits <- search_papers(df, query = "phishing", year = 2023)
  expect_equal(nrow(hits), 0L)
})

test_that("search_papers warns and returns empty result for non-data.frame input", {
  expect_warning(out <- search_papers(NULL), "must be a data.frame")
  expect_s3_class(out, "data.frame")
  expect_equal(nrow(out), 0L)
  expect_true(all(c("id", "title", "abstract") %in% names(out)))
})

test_that("search_papers handles empty data.frame", {
  empty <- data.frame(id = character(0), title = character(0),
                      abstract = character(0), published_date = character(0),
                      stringsAsFactors = FALSE)
  expect_equal(nrow(search_papers(empty, query = "anything")), 0L)
})
