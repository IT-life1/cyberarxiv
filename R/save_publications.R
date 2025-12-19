#' Save arXiv publications to DuckDB (single table)
#'
#' @param data data.frame from get_arxiv_papers()
#' @param db_path optional path to duckdb file (default: data/cyberarxiv.duckdb or env/option)
#' @return invisible list(stats)
#' @noRd
.normalize_list_to_csv <- function(x) {
  # "A; B; C" -> "A, B, C"
  vapply(x, function(s) {
    s <- trimws(as.character(s))
    if (is.na(s) || !nzchar(s)) return("")
    parts <- trimws(unlist(strsplit(s, ";", fixed = TRUE)))
    parts <- parts[nzchar(parts)]
    paste(parts, collapse = ", ")
  }, character(1))
}

.arxiv_category_map <- c(
  "cond-mat.mtrl-sci"     = "Condensed Matter: Materials Science",
  "cond-mat.stat-mech"    = "Condensed Matter: Statistical Mechanics",
  "cs.AI"                 = "Computer Science: Artificial Intelligence",
  "cs.AR"                 = "Computer Science: Hardware Architecture",
  "cs.CC"                 = "Computer Science: Computational Complexity",
  "cs.CE"                 = "Computer Science: Computational Engineering, Finance, and Science",
  "cs.CL"                 = "Computer Science: Computation and Language",
  "cs.CR"                 = "Computer Science: Cryptography and Security",
  "cs.CV"                 = "Computer Science: Computer Vision and Pattern Recognition",
  "cs.CY"                 = "Computer Science: Computers and Society",
  "cs.DB"                 = "Computer Science: Databases",
  "cs.DC"                 = "Computer Science: Distributed and Parallel and Cluster Computing",
  "cs.DM"                 = "Computer Science: Discrete Mathematics",
  "cs.DS"                 = "Computer Science: Data Structures and Algorithms",
  "cs.ET"                 = "Computer Science: Emerging Technologies",
  "cs.FL"                 = "Computer Science: Formal Languages and Automata Theory",
  "cs.GT"                 = "Computer Science and Game Theory",
  "cs.HC"                 = "Computer Science: Human-Computer Interaction",
  "cs.IR"                 = "Computer Science: Information Retrieval",
  "cs.IT"                 = "Computer Science: Information Theory",
  "cs.LG"                 = "Computer Science: Machine Learning",
  "cs.LO"                 = "Computer Science: Logic in Computer Science",
  "cs.MA"                 = "Computer Science: Multiagent Systems",
  "cs.MM"                 = "Computer Science: Multimedia",
  "cs.MS"                 = "Computer Science: Mathematical Software",
  "cs.NE"                 = "Computer Science: Neural and Evolutionary Computing",
  "cs.NI"                 = "Computer Science: Networking and Internet Architecture",
  "cs.OS"                 = "Computer Science: Operating Systems",
  "cs.PF"                 = "Computer Science: Performance",
  "cs.PL"                 = "Computer Science: Programming Languages",
  "cs.RO"                 = "Computer Science: Robotics",
  "cs.SD"                 = "Computer Science: Sound",
  "cs.SE"                 = "Computer Science: Software Engineering",
  "cs.SI"                 = "Computer Science: Social and Information Networks",
  "econ.EM"               = "Economics: Econometrics",
  "econ.GN"               = "Economics: General Economics",
  "econ.TH"               = "Economics: Theoretical Economics",
  "eess.AS"               = "Electrical Engineering and Systems Science: Audio and Speech Processing",
  "eess.IV"               = "Electrical Engineering and Systems Science: Image and Video Processing",
  "eess.SP"               = "Electrical Engineering and Systems Science: Signal Processing",
  "eess.SY"               = "Electrical Engineering and Systems Science: Systems and Control",
  "hep-ex"                = "High Energy Physics: Experiment",
  "hep-ph"                = "High Energy Physics: Phenomenology",
  "math.CA"               = "Mathematics: Classical Analysis and ODEs",
  "math.CT"               = "Mathematics: Category Theory",
  "math.DS"               = "Mathematics: Dynamical Systems",
  "math.GR"               = "Mathematics: Group Theory",
  "math.NA"               = "Mathematics: Numerical Analysis",
  "math.OC"               = "Mathematics: Optimization and Control",
  "math.PR"               = "Mathematics: Probability",
  "math.RA"               = "Mathematics: Rings and Algebras",
  "math.RT"               = "Mathematics: Representation Theory",
  "math.SP"               = "Mathematics: Spectral Theory",
  "math.ST"               = "Mathematics: Statistics Theory",
  "physics.ao-ph"         = "Physics: Atmospheric and Oceanic Physics",
  "physics.bio-ph"        = "Physics: Biological Physics",
  "physics.chem-ph"       = "Physics: Chemical Physics",
  "physics.flu-dyn"       = "Physics: Fluid Dynamics",
  "physics.geo-ph"        = "Physics: Geophysics",
  "physics.optics"        = "Physics: Optics",
  "q-bio.BM"              = "Quantitative Biology: Biomolecules",
  "q-bio.MN"              = "Quantitative Biology: Molecular Networks",
  "q-bio.NC"              = "Quantitative Biology: Neurons and Cognition",
  "q-bio.QM"              = "Quantitative Biology: Quantitative Methods",
  "q-fin.CP"              = "Quantitative Finance: Computational Finance",
  "q-fin.GN"              = "Quantitative Finance: General Finance",
  "q-fin.RM"              = "Quantitative Finance: Risk Management",
  "quant-ph"              = "Quantum Physics",
  "stat.AP"               = "Statistics: Applications",
  "stat.CO"               = "Statistics: Computation",
  "stat.ME"               = "Statistics: Methodology",
  "stat.ML"               = "Statistics: Machine Learning"
)

.map_categories_to_names_csv <- function(x) {
  vapply(x, function(s) {
    s <- trimws(as.character(s))
    if (is.na(s) || !nzchar(s)) return("")
    codes <- trimws(unlist(strsplit(s, ";", fixed = TRUE)))
    codes <- codes[nzchar(codes)]
    names <- unname(.arxiv_category_map[codes])
    names[is.na(names)] <- codes[is.na(names)]
    paste(names, collapse = ", ")
  }, character(1))
}




save_publications <- function(data, db_path = NULL) {
  if (is.null(db_path)) db_path <- .cyberarxiv_db_path()

  stopifnot(is.data.frame(data))
  required <- c("id","link","title","authors","abstract","categories","published_date","updated_date","tag")
  miss <- setdiff(required, names(data))
  if (length(miss)) stop("Missing columns: ", paste(miss, collapse = ", "))

  if (nrow(data) == 0L) {
    return(invisible(list(inserted = 0L, updated = 0L, skipped = 0L, db_path = db_path)))
  }

  con <- .cyberarxiv_connect(db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)


  to_time <- function(x) {
    if (inherits(x, "POSIXct")) return(x)
    as.POSIXct(
      x, tz = "UTC",
      tryFormats = c("%Y-%m-%dT%H:%M:%OSZ", "%Y-%m-%d %H:%M:%OS")
    )
  }

  df <- data.frame(
    paper_id       = as.character(data$id),
    link           = as.character(data$link),
    title          = as.character(data$title),
    authors        = .normalize_list_to_csv(data$authors),
    abstract       = as.character(data$abstract),
    categories     = .map_categories_to_names_csv(data$categories),
    published_date = to_time(data$published_date),
    updated_date   = to_time(data$updated_date),
    tag = as.character(data$tag),
    stringsAsFactors = FALSE
  )


  DBI::dbWriteTable(con, "stg_papers", df, overwrite = TRUE)

  updated <- DBI::dbExecute(con, "
  UPDATE papers AS p
  SET
    link = s.link,
    title = s.title,
    authors = s.authors,
    abstract = s.abstract,
    categories = s.categories,
    published_date = s.published_date,
    updated_date = s.updated_date,
    ingested_at = now(),
    tag = COALESCE(NULLIF(trim(s.tag), ''), p.tag)
  FROM stg_papers AS s
  WHERE p.paper_id = s.paper_id
    AND s.paper_id IS NOT NULL
    AND s.paper_id <> ''
    AND (
      p.updated_date IS NULL
      OR s.updated_date IS NULL
      OR s.updated_date > p.updated_date
    );
")

  # 2) INSERT new paper_id
  inserted <- DBI::dbExecute(con, "
  INSERT INTO papers (
    paper_id, link, title, authors, abstract,
    categories, published_date, updated_date, tag
  )
  SELECT
    s.paper_id, s.link, s.title, s.authors, s.abstract,
    s.categories, s.published_date, s.updated_date, s.tag
  FROM stg_papers s
  WHERE s.paper_id IS NOT NULL
    AND s.paper_id <> ''
    AND NOT EXISTS (
      SELECT 1
      FROM papers p
      WHERE p.paper_id = s.paper_id
    );
")

  DBI::dbExecute(con, "DROP TABLE IF EXISTS stg_papers;")

  total <- nrow(df)
  skipped <- total - as.integer(inserted) - as.integer(updated)

  invisible(list(
    inserted = as.integer(inserted),
    updated  = as.integer(updated),
    skipped  = as.integer(skipped),
    db_path  = db_path
  ))
}