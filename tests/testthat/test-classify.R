test_that("load_keyword_config parses a simple YAML keyword list", {
  skip_if_not_installed("yaml")

  yml <- tempfile(fileext = ".yml")
  on.exit(unlink(yml), add = TRUE)
  writeLines(c(
    "Malware:",
    "  - ransomware",
    "  - trojan",
    "Phishing:",
    "  - phishing",
    "  - smishing"
  ), yml)

  cfg <- load_keyword_config(yml)

  expect_named(cfg, c("keywords", "weights"))
  expect_setequal(names(cfg$keywords), c("Malware", "Phishing"))
  expect_setequal(cfg$keywords$Malware, c("ransomware", "trojan"))
  expect_setequal(cfg$keywords$Phishing, c("phishing", "smishing"))
})

test_that("load_keyword_config parses structured form with weights", {
  skip_if_not_installed("yaml")

  yml <- tempfile(fileext = ".yml")
  on.exit(unlink(yml), add = TRUE)
  writeLines(c(
    "Cryptography:",
    "  keywords:",
    "    - aes",
    "    - rsa",
    "  weights:",
    "    aes: 2",
    "    rsa: 3"
  ), yml)

  cfg <- load_keyword_config(yml)
  expect_setequal(cfg$keywords$Cryptography, c("aes", "rsa"))
  expect_equal(cfg$weights$Cryptography$aes, 2)
  expect_equal(cfg$weights$Cryptography$rsa, 3)
})

test_that("load_keyword_config errors on missing 'keywords' in structured entry", {
  skip_if_not_installed("yaml")

  yml <- tempfile(fileext = ".yml")
  on.exit(unlink(yml), add = TRUE)
  writeLines(c(
    "Broken:",
    "  weights:",
    "    foo: 1"
  ), yml)

  expect_error(load_keyword_config(yml), "missing 'keywords' field")
})

test_that("load_keyword_config errors on unsupported file extension", {
  bad <- tempfile(fileext = ".txt")
  file.create(bad)
  on.exit(unlink(bad), add = TRUE)
  expect_error(load_keyword_config(bad), "Unsupported file format")
})

test_that("classify_data rejects non-data.frame and missing abstract", {
  expect_error(classify_data(NULL), "must be a data.frame")
  expect_error(classify_data(list(a = 1)), "must be a data.frame")
  expect_error(classify_data(data.frame(title = "x")), "abstract.*missing")
})

test_that("classify_data on empty input returns an empty data.frame with tag", {
  empty <- data.frame(title = character(0), abstract = character(0),
                      stringsAsFactors = FALSE)
  out <- classify_data(empty)
  expect_s3_class(out, "data.frame")
  expect_true("tag" %in% names(out))
  expect_equal(nrow(out), 0L)
})
