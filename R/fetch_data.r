library(httr2)
library(xml2)
resp <- request("https://export.arxiv.org/api/query") |>
  req_url_query(
    search_query = "cat:cs.CR",
    max_results = 5
  ) |>
  req_user_agent("arxiv-test/0.1") |>
  req_perform()

doc <- read_xml(resp_body_raw(resp))

ns <- xml_ns(doc)
ns <- xml_ns_rename(ns, d1 = "atom")

entries <- xml_find_all(doc, ".//atom:entry", ns)

for (i in seq_along(entries)) {
  entry <- entries[[i]]

  id <- xml_text(xml_find_first(entry, "./atom:id", ns))
  title <- xml_text(xml_find_first(entry, "./atom:title", ns))
  updated <- xml_text(xml_find_first(entry, "./atom:updated", ns))

  authors <- xml_text(
    xml_find_all(entry, "./atom:author/atom:name", ns)
  )

  cat("-----\n")
  cat("ID:      ", id, "\n")
  cat("Title:   ", title, "\n")
  cat("Updated: ", updated, "\n")
  cat("Authors: ", paste(authors, collapse = ", "), "\n")
}
