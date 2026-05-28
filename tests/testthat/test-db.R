test_that(".cyberarxiv_init_schema creates papers table with expected columns", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")

  init_schema <- getFromNamespace(".cyberarxiv_init_schema", "cyberarxiv")

  db_path <- tempfile(fileext = ".duckdb")
  on.exit(unlink(db_path, force = TRUE), add = TRUE)

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_path, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  init_schema(con)

  tables <- DBI::dbListTables(con)
  expect_true("papers" %in% tables)

  cols <- DBI::dbGetQuery(
    con,
    "SELECT column_name FROM information_schema.columns
     WHERE table_name = 'papers'"
  )$column_name
  for (required in c("paper_id", "title", "abstract", "published_date",
                     "tag", "ml_results", "source", "language")) {
    expect_true(required %in% cols, info = paste("missing column:", required))
  }
})

test_that(".cyberarxiv_init_schema is idempotent", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")

  init_schema <- getFromNamespace(".cyberarxiv_init_schema", "cyberarxiv")

  db_path <- tempfile(fileext = ".duckdb")
  on.exit(unlink(db_path, force = TRUE), add = TRUE)

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_path, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  init_schema(con)
  cols_before <- DBI::dbGetQuery(
    con,
    "SELECT column_name FROM information_schema.columns
     WHERE table_name = 'papers' ORDER BY column_name"
  )$column_name

  # Second call must not fail or change the schema
  expect_silent(init_schema(con))
  cols_after <- DBI::dbGetQuery(
    con,
    "SELECT column_name FROM information_schema.columns
     WHERE table_name = 'papers' ORDER BY column_name"
  )$column_name

  expect_identical(cols_before, cols_after)
})

test_that("get_ml_task_ids returns character(0) when DB file is missing", {
  # No DB file, no surprises — should not raise.
  missing_path <- tempfile(fileext = ".duckdb")
  expect_false(file.exists(missing_path))
  expect_identical(get_ml_task_ids(db_path = missing_path), character(0))
})

test_that("get_ml_task_ids returns character(0) on a fresh empty DB", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")

  init_schema <- getFromNamespace(".cyberarxiv_init_schema", "cyberarxiv")
  db_path <- tempfile(fileext = ".duckdb")
  on.exit(unlink(db_path, force = TRUE), add = TRUE)

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_path, read_only = FALSE)
  init_schema(con)
  DBI::dbDisconnect(con, shutdown = TRUE)

  expect_identical(get_ml_task_ids(db_path = db_path), character(0))
})

test_that("get_ml_task_ids returns task IDs from ml_results JSON", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")

  init_schema <- getFromNamespace(".cyberarxiv_init_schema", "cyberarxiv")
  db_path <- tempfile(fileext = ".duckdb")
  on.exit(unlink(db_path, force = TRUE), add = TRUE)

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_path, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  init_schema(con)

  DBI::dbExecute(con, "
    INSERT INTO papers (paper_id, title, abstract, published_date, source, language, ml_results)
    VALUES
      ('p1', 'Paper One', 'Abstract one.', NOW(), 'arxiv', 'en',
       '{\"default\":{\"label\":\"relevant\",\"score\":0.91}}'),
      ('p2', 'Paper Two', 'Abstract two.', NOW(), 'arxiv', 'en',
       '{\"malware\":{\"label\":\"relevant\",\"score\":0.78}}'),
      ('p3', 'Paper Three', 'Abstract three.', NOW(), 'arxiv', 'en', NULL)
  ")

  ids <- get_ml_task_ids(db_path = db_path)
  expect_true("default" %in% ids)
  expect_true("malware" %in% ids)
  expect_false("nonexistent" %in% ids)
})

test_that("get_ml_task_ids handles multiple tasks in one record", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")

  init_schema <- getFromNamespace(".cyberarxiv_init_schema", "cyberarxiv")
  db_path <- tempfile(fileext = ".duckdb")
  on.exit(unlink(db_path, force = TRUE), add = TRUE)

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_path, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  init_schema(con)

  DBI::dbExecute(con, "
    INSERT INTO papers (paper_id, title, abstract, published_date, source, language, ml_results)
    VALUES
      ('p1', 'Multi-task paper', 'Abstract.', NOW(), 'arxiv', 'en',
       '{\"default\":{\"label\":\"relevant\",\"score\":0.9},\"malware\":{\"label\":\"irrelevant\",\"score\":0.3}}')
  ")

  ids <- get_ml_task_ids(db_path = db_path)
  expect_true("default" %in% ids)
  expect_true("malware" %in% ids)
  expect_equal(length(ids), 2L)
})

test_that(".cyberarxiv_init_schema creates all expected indexes", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")

  init_schema <- getFromNamespace(".cyberarxiv_init_schema", "cyberarxiv")
  db_path <- tempfile(fileext = ".duckdb")
  on.exit(unlink(db_path, force = TRUE), add = TRUE)

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_path, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  init_schema(con)

  indexes <- DBI::dbGetQuery(
    con,
    "SELECT index_name FROM duckdb_indexes() WHERE table_name = 'papers'"
  )$index_name

  expect_true("idx_papers_paper_id"   %in% indexes)
  expect_true("idx_papers_published"  %in% indexes)
  expect_true("idx_papers_tag"        %in% indexes)
  expect_true("idx_papers_source"     %in% indexes)
  expect_true("idx_papers_language"   %in% indexes)
})
