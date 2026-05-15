test_that(".interpolate_string substitutes ${VAR} and ${VAR:-default}", {
  fn <- getFromNamespace(".interpolate_string", "cyberarxiv")
  mv <- new.env(parent = emptyenv())

  Sys.setenv(CYBERARXIV_TEST_VAR = "hit")
  on.exit(Sys.unsetenv("CYBERARXIV_TEST_VAR"), add = TRUE)

  expect_identical(fn("${CYBERARXIV_TEST_VAR}", mv), "hit")
  expect_identical(fn("${CYBERARXIV_TEST_VAR:-other}", mv), "hit")
  expect_identical(fn("prefix-${CYBERARXIV_TEST_VAR}-suf", mv),
                   "prefix-hit-suf")
  expect_identical(fn("no placeholder here", mv), "no placeholder here")
  expect_identical(fn("", mv), "")
  expect_length(ls(mv), 0L)
})

test_that(".interpolate_string falls back to default and tracks missing", {
  fn <- getFromNamespace(".interpolate_string", "cyberarxiv")
  mv <- new.env(parent = emptyenv())

  Sys.unsetenv("CYBERARXIV_NEVER_SET")

  expect_identical(fn("${CYBERARXIV_NEVER_SET:-fallback}", mv), "fallback")
  # default-with-explicit-empty should NOT be flagged as missing
  expect_identical(fn("${CYBERARXIV_NEVER_SET:-}", mv), "")
  expect_length(ls(mv), 0L)

  # No default + unset → tracked as missing, resolved to empty string
  expect_identical(fn("${CYBERARXIV_NEVER_SET}", mv), "")
  expect_true("CYBERARXIV_NEVER_SET" %in% ls(mv))
})

test_that(".interpolate_env recurses into nested lists and char vectors", {
  fn <- getFromNamespace(".interpolate_env", "cyberarxiv")
  mv <- new.env(parent = emptyenv())

  Sys.setenv(CYBERARXIV_TEST_VAR = "value")
  on.exit(Sys.unsetenv("CYBERARXIV_TEST_VAR"), add = TRUE)

  spec <- list(
    auth = list(type = "bearer", token = "${CYBERARXIV_TEST_VAR}"),
    query = list(params = list(q = "x ${CYBERARXIV_TEST_VAR:-fb}")),
    enabled = TRUE,
    scalars = c("${CYBERARXIV_TEST_VAR}", "${MISSING_X:-z}")
  )
  out <- fn(spec, mv)

  expect_identical(out$auth$token, "value")
  expect_identical(out$query$params$q, "x value")
  expect_identical(out$enabled, TRUE)               # non-strings untouched
  expect_identical(out$scalars, c("value", "z"))
})

test_that("list_collectors returns the expected shape", {
  # Always a data.frame with these columns, even if no specs are found.
  df <- list_collectors()
  expect_s3_class(df, "data.frame")
  expect_named(df, c("name", "label", "type", "enabled"))
  expect_type(df$enabled, "logical")
})
