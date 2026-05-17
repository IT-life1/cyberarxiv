#' Search papers
#' @param data dataframe from load_raw_data()
#' @param query text to search
#' @param year year filter (optional)
#'
#' @return filtered dataframe
#' @export
search_papers <- function(data, query = NULL, year = NULL) {
  # FIX: Validate input - handle NULL and non-data.frame inputs
  if (is.null(data) || !is.data.frame(data)) {
    warning("search_papers: 'data' must be a data.frame, returning empty result")
    return(.empty_search_result())
  }

  if (nrow(data) == 0) return(data)

  result <- data

  if (!is.null(query)) {
    query <- tolower(query)
    title_match <- grepl(query, tolower(data$title), ignore.case = FALSE)
    abstract_match <- grepl(query, tolower(data$abstract), ignore.case = FALSE)
    result <- data[title_match | abstract_match, , drop = FALSE]
  }

  if (!is.null(year)) {
    # FIX: Handle NA dates properly - use which() to avoid NA indexing
    years <- as.integer(format(as.POSIXct(result$published_date, tz = "UTC"), "%Y"))
    valid_years <- !is.na(years)
    result <- result[valid_years & (years == year), , drop = FALSE]
  }

  rownames(result) <- NULL
  result
}

#' @noRd
.empty_search_result <- function() {
  data.frame(
    id = character(0),
    link = character(0),
    title = character(0),
    authors = character(0),
    abstract = character(0),
    categories = character(0),
    published_date = character(0),
    updated_date = character(0),
    tag = character(0),
    stringsAsFactors = FALSE
  )
}

#' Load keyword classifier configuration from YAML or JSON
#'
#' @param path Path to YAML or JSON file.
#' @return Named list: \code{list(keywords = list(...), weights = list(...))}.
#' @export
load_keyword_config <- function(path) {
  ext <- tolower(tools::file_ext(path))
  if (ext %in% c("yml", "yaml")) {
    if (!requireNamespace("yaml", quietly = TRUE))
      stop("Package 'yaml' is required. install.packages('yaml')")
    cfg <- yaml::read_yaml(path)
  } else if (ext == "json") {
    cfg <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  } else {
    stop("Unsupported file format '", ext, "'. Use .yml, .yaml, or .json")
  }

  keywords <- list()
  weights  <- list()

  for (cls in names(cfg)) {
    entry <- cfg[[cls]]
    if (is.character(entry) || is.null(names(entry))) {
      # Simple list of keywords
      keywords[[cls]] <- as.character(unlist(entry))
      weights[[cls]]  <- list()
    } else {
      # Structured: entry$keywords + optional entry$weights
      kws <- entry[["keywords"]]
      if (is.null(kws))
        stop("Class '", cls, "': missing 'keywords' field in config")
      keywords[[cls]] <- as.character(unlist(kws))
      weights[[cls]]  <- as.list(entry[["weights"]] %||% list())
    }
  }

  list(keywords = keywords, weights = weights)
}

#' Classify data
#'
#' Classifies publications by cybersecurity topics using keyword matching.
#'
#' @param data dataframe from load_raw_data()
#' @param keywords_file Optional path to a YAML or JSON keyword config file.
#'   If NULL, uses the built-in keyword dictionary. Use \code{load_keyword_config()}
#'   to inspect or modify the format. Template: \code{system.file("keywords.yml", package = "cyberarxiv")}.
#'
#' @return data.frame with additional 'tag' column containing topic assignments
#' @export
classify_data <- function(data, keywords_file = NULL) {
  if (is.null(data) || !is.data.frame(data))
    stop("'data' must be a data.frame")
  if (!"abstract" %in% names(data))
    stop("Column 'abstract' is missing from data")
  if (nrow(data) == 0) {
    data$tag <- character(0)
    return(data)
  }

  # Load keyword config: external file or built-in
  if (!is.null(keywords_file)) {
    kw_cfg       <- load_keyword_config(keywords_file)
    tag_keywords <- kw_cfg$keywords
    tag_weights  <- kw_cfg$weights
  } else {
    tag_weights  <- list()
  }

  predefined_tags <- c(
    "Threat Actor",
    "Cryptography",
    "Privacy Protection",
    "Vulnerability",
    "Exploit",
    "Attack Vector",
    "Malware",
    "Social Engineering",
    "Network Attack",
    "Log Event",
    "Incident",
    "ML Methodology",
    "Model Architecture",
    "Learning Theory",
    "Evaluation & Benchmarking",
    "ML/AI Security",
    "other"
  )

  # When external config is loaded, override predefined_tags with config keys
  if (!is.null(keywords_file)) {
    predefined_tags <- c(names(tag_keywords), "other")
  }

  # Built-in tag_keywords (used only when no external file provided)
  if (is.null(keywords_file)) tag_keywords <- list(

    "Threat Actor" = c(
      "threat actor", "attacker", "adversary", "hacker", "insider",
      "malicious actor", "cybercriminal", "nation state", "apt",
      "script kiddie", "fraudster", "phisher", "threat agent",
      "perpetrator", "offender", "black hat", "red team",
      "blue team", "criminal group", "hacktivist",
      "organized crime", "state sponsored", "internal attacker",
      "external attacker", "rogue employee"
    ),

    "Cryptography" = c(
      "cryptography", "encryption", "decryption", "cipher",
      "cryptosystem", "cryptanalysis", "symmetric encryption",
      "asymmetric encryption", "public key", "private key",
      "hash function", "digital signature", "key management",
      "key exchange", "aes", "rsa", "ecc",
      "tls", "ssl", "cryptographic protocol",
      "key derivation", "salt", "hashing", "message authentication"
    ),

    "Vulnerability" = c(
      "vulnerability", "software vulnerability", "security flaw",
      "weakness", "bug", "cve", "zero day",
      "misconfiguration", "exposure", "unpatched",
      "outdated software", "insecure configuration", "cvss",
      "attack surface", "known vulnerability", "unknown vulnerability",
      "logic flaw", "input validation", "buffer overflow",
      "integer overflow", "race condition", "use after free",
      "memory corruption", "security defect"
    ),

    "Exploit" = c(
      "exploit", "exploitation", "exploit code", "payload",
      "shellcode", "weaponized exploit", "exploit kit",
      "remote code execution", "rce", "privilege escalation",
      "local privilege escalation", "take advantage",
      "proof of concept", "poc", "arbitrary code execution",
      "sandbox escape", "command injection",
      "sql injection exploit", "xss exploit",
      "heap spray", "return oriented programming",
      "rop chain", "exploit chain", "attack payload"
    ),

    "Attack Vector" = c(
      "attack vector", "initial access", "entry point",
      "attack path", "delivery method", "infection vector",
      "phishing email", "malicious attachment", "drive by download",
      "watering hole", "supply chain attack",
      "remote access", "open port", "exposed service",
      "credential abuse", "password reuse", "brute force",
      "vpn compromise", "rdp attack", "email attack",
      "web attack", "usb attack", "network based attack",
      "lateral movement"
    ),
    "Privacy Protection" = c(
      "privacy", "data privacy", "privacy preserving",
      "privacy protection", "personal data",
      "data anonymization", "anonymization",
      "pseudonymization", "data masking",
      "k anonymity", "l diversity", "t closeness",
      "differential privacy", "privacy budget",
      "private data", "sensitive data",
      "data leakage", "privacy leakage",
      "confidentiality", "data protection",
      "gdpr", "privacy regulation",
      "privacy risk", "privacy attack"
    ),

    "Learning Theory" = c(
      "learning theory", "statistical learning",
      "generalization", "generalization bound",
      "sample complexity", "vc dimension",
      "pac learning", "probably approximately correct",
      "theoretical guarantee", "convergence",
      "convergence rate", "optimization theory",
      "risk minimization", "empirical risk",
      "structural risk minimization",
      "bias variance tradeoff",
      "theoretical analysis", "asymptotic behavior",
      "proof", "theorem",
      "lemma", "proposition",
      "formal analysis", "theoretical framework"
    ),

    "Model Architecture" = c(
      "model architecture", "neural architecture",
      "convolutional neural network", "cnn",
      "recurrent neural network", "rnn",
      "long short term memory", "lstm",
      "gated recurrent unit", "gru",
      "transformer", "attention mechanism",
      "self attention", "encoder decoder",
      "graph neural network", "gnn",
      "autoencoder", "variational autoencoder",
      "vae", "residual network",
      "resnet", "deep architecture",
      "layer design", "model depth"
    ),

    "ML Methodology" = c(
      "machine learning", "supervised learning", "unsupervised learning",
      "semi supervised learning", "reinforcement learning",
      "deep learning", "neural network", "training process",
      "model training", "model optimization",
      "loss function", "objective function",
      "gradient descent", "stochastic gradient descent",
      "backpropagation", "regularization",
      "overfitting", "underfitting",
      "hyperparameter tuning", "cross validation",
      "feature extraction", "feature selection",
      "representation learning", "learning algorithm"
    ),

    "Evaluation & Benchmarking" = c(
      "evaluation", "benchmark",
      "experimental evaluation", "performance evaluation",
      "benchmark dataset", "comparison",
      "baseline", "state of the art",
      "sota", "experimental results",
      "accuracy", "precision", "recall",
      "f1 score", "auc",
      "roc curve", "confusion matrix",
      "evaluation metric", "performance metric",
      "scalability", "efficiency",
      "runtime", "computational cost",
      "memory consumption"
    ),


    "Malware" = c(
      "malware", "ransomware", "trojan", "worm",
      "spyware", "rootkit", "backdoor", "botnet",
      "adware", "fileless malware", "loader",
      "dropper", "command and control", "c2 server",
      "malicious binary", "malicious script",
      "crimeware", "banking trojan", "keylogger",
      "stealer", "cryptominer", "malicious dll",
      "payload delivery", "persistent malware"
    ),

    "Log Event" = c(
      "log", "event", "event log", "audit log",
      "security log", "syslog", "telemetry",
      "log entry", "log file", "audit trail",
      "log analysis", "event correlation", "siem",
      "alert", "alerting", "detection event",
      "security event", "anomaly event",
      "monitoring data", "log collection",
      "log aggregation", "event monitoring",
      "log retention", "forensic log"
    ),

    "Incident" = c(
      "incident", "security incident", "cyber incident",
      "breach", "data breach", "intrusion",
      "compromise", "security breach", "attack incident",
      "incident response", "incident handling",
      "incident management", "containment",
      "eradication", "recovery",
      "post incident analysis", "lessons learned",
      "forensic investigation", "root cause analysis",
      "incident timeline", "response playbook",
      "security escalation", "incident report",
      "major incident"
    ),

    "Social Engineering" = c(
      "social engineering", "phishing", "spear phishing",
      "whaling", "vishing", "smishing",
      "pretexting", "baiting", "impersonation",
      "credential harvesting", "password phishing",
      "business email compromise", "bec",
      "ceo fraud", "human factor",
      "psychological manipulation", "trust exploitation",
      "authority exploitation", "urgency tactic",
      "fear tactic", "social proof",
      "email deception", "voice phishing",
      "sms phishing", "fake login page"
    ),

    "Network Attack" = c(
      "network attack", "ddos", "dos attack",
      "packet sniffing", "man in the middle",
      "mitm attack", "port scanning",
      "network reconnaissance", "arp spoofing",
      "dns poisoning", "ip spoofing",
      "session hijacking", "tcp reset",
      "udp flood", "icmp flood",
      "network intrusion", "lateral movement",
      "network pivoting", "vlan hopping",
      "mac flooding", "rogue access point",
      "wifi attack", "wireless attack",
      "network exploitation"
    ),

    "ML/AI Security" = c(
      "machine learning security", "ai security",
      "adversarial attack", "data poisoning",
      "model stealing", "membership inference",
      "model inversion", "backdoor attack",
      "evasion attack", "adversarial example",
      "adversarial training", "differential privacy",
      "federated learning", "robust machine learning",
      "model watermarking", "secure aggregation",
      "trustworthy ai", "responsible ai",
      "ai safety", "algorithmic bias",
      "explainable ai", "model vulnerability",
      "ml threat detection", "ai based detection"
    )
  ) # end built-in tag_keywords

  classify_by_keywords <- function(abstract) {
    if (is.na(abstract) || abstract == "") return("other")

    abstract_lower <- tolower(abstract)
    scores <- numeric(length(predefined_tags) - 1)
    names(scores) <- predefined_tags[seq_len(length(predefined_tags) - 1L)]

    for (tag_name in names(scores)) {
      keywords      <- tag_keywords[[tag_name]]
      cls_weights   <- tag_weights[[tag_name]] %||% list()
      keyword_count <- 0

      for (keyword in keywords) {
        if (grepl(paste0("\\b", keyword, "\\b"), abstract_lower, ignore.case = TRUE)) {
          w <- cls_weights[[keyword]]
          keyword_count <- keyword_count + if (!is.null(w)) w else nchar(keyword) * 0.1
        }
      }

      scores[tag_name] <- keyword_count
    }

    max_score <- max(scores)
    if (max_score > 0) {
      top_tags <- names(scores[scores == max_score])
      # FIX: Deterministic tie-breaking by returning first alphabetically
      return(sort(top_tags)[1])
    } else {
      return("other")
    }
  }

  create_topic_tags <- function(data) {
    title_col <- if ("title" %in% names(data)) data$title else rep("", nrow(data))
    text_for_classification <- ifelse(
      is.na(data$abstract) | !nzchar(trimws(data$abstract)),
      title_col,
      paste(title_col, data$abstract)
    )
    data$tag <- vapply(text_for_classification, classify_by_keywords, character(1),
                       USE.NAMES = FALSE)
    return(data)
  }

  return(create_topic_tags(data))
}

#' ETL
#'
#' Pipeline that fetches papers from configured collectors, classifies them,
#' and updates the database.
#'
#' Follows the pattern: fetch -> DB (raw) -> classify -> update tags in DB.
#' Papers are persisted before classification, so a classifier failure never causes data loss.
#'
#' @param max_results How many papers to fetch per source (integer). When `only_new = TRUE`,
#'   this is the number of *new* (not-yet-stored) papers to collect.
#' @param only_new Logical. If TRUE, skips papers already present in the database
#'   and stops once `max_results` genuinely new papers have been saved.
#'   Defaults to FALSE (standard behaviour: fetch `max_results` and upsert all).
#' @param db_path Path to DuckDB file. If NULL, uses the package default.
#' @param sources Character vector of collector names to run. NULL (default) runs all
#'   enabled collectors. See \code{\link{list_collectors}}.
#' @param collectors_dir Additional directory to scan for collector YAML files.
#' @param param_overrides Named list of per-collector parameter overrides passed to
#'   \code{collect_all()}. E.g. \code{list(arxiv = list(params = list(search_query = "...")))}
#' @param keywords_file Optional path to a YAML/JSON keyword config file passed to
#'   \code{classify_data()}. NULL uses the built-in dictionary.
#'
#' @export
etl <- function(max_results = 100, only_new = FALSE, db_path = NULL,
                sources = NULL, collectors_dir = NULL, param_overrides = list(),
                keywords_file = NULL) {
  if (!only_new) {
    papers <- collect_all(sources = sources, max_results = max_results,
                          extra_dirs = collectors_dir, param_overrides = param_overrides)
    if (nrow(papers) == 0L) {
      message("No papers fetched.")
      return(invisible(list(inserted = 0L, updated = 0L, skipped = 0L)))
    }
  } else {
    papers <- .fetch_only_new_multi(sources, max_results, db_path,
                                    collectors_dir, param_overrides)
    if (is.null(papers)) {
      return(invisible(list(inserted = 0L, updated = 0L, skipped = 0L)))
    }
  }

  papers$tag <- ""
  if (!"language" %in% names(papers)) papers$language <- NA_character_
  message("Saving ", nrow(papers), " paper(s) to DB...")
  result <- save_publications(papers, db_path = db_path)

  message("Classifying...")
  classified <- .classify_by_lang(papers, keywords_file)
  .update_tags(classified, db_path = db_path)

  message("Done: inserted=", result$inserted, ", updated=", result$updated,
          ", skipped=", result$skipped)
  invisible(result)
}

#' @noRd
.fetch_only_new_multi <- function(sources, max_results, db_path,
                                  collectors_dir, param_overrides = list()) {
  want_new  <- as.integer(max_results)
  max_fetch <- max(want_new * 5L, 100L)

  existing_ids <- .load_existing_ids(db_path)
  message("DB contains ", length(existing_ids), " known paper ID(s).")

  all_papers <- collect_all(sources = sources, max_results = max_fetch,
                             extra_dirs = collectors_dir,
                             param_overrides = param_overrides)

  if (nrow(all_papers) == 0L) {
    message("No papers fetched from any source.")
    return(NULL)
  }

  new_papers <- all_papers[!all_papers$id %in% existing_ids, , drop = FALSE]

  if (nrow(new_papers) == 0L) {
    message("No new papers found after checking ", nrow(all_papers), " fetched.")
    return(NULL)
  }

  rownames(new_papers) <- NULL
  new_papers[seq_len(min(want_new, nrow(new_papers))), , drop = FALSE]
}

#' @noRd
.classify_by_lang <- function(data, keywords_file = NULL) {
  if (is.null(data) || nrow(data) == 0L) return(data)

  ru_kw <- system.file("keywords_ru.yml", package = "cyberarxiv")
  lang_col <- if ("language" %in% names(data)) data$language else rep("en", nrow(data))
  lang_col[is.na(lang_col) | !nzchar(lang_col)] <- "en"

  is_ru <- lang_col == "ru"

  en_data <- data[!is_ru, , drop = FALSE]
  ru_data <- data[is_ru,  , drop = FALSE]

  en_out <- if (nrow(en_data) > 0L)
    classify_data(en_data, keywords_file = keywords_file)
  else en_data

  ru_out <- if (nrow(ru_data) > 0L && nzchar(ru_kw) && file.exists(ru_kw))
    classify_data(ru_data, keywords_file = ru_kw)
  else if (nrow(ru_data) > 0L)
    classify_data(ru_data, keywords_file = keywords_file)
  else ru_data

  rbind(en_out, ru_out)
}

#' @noRd
.update_tags <- function(data, db_path = NULL) {
  if (is.null(db_path)) db_path <- .cyberarxiv_db_path()
  if (!file.exists(db_path) || nrow(data) == 0L) return(invisible(NULL))

  con <- .cyberarxiv_connect(db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  stg <- data.frame(
    paper_id = as.character(data$id),
    tag      = as.character(data$tag),
    stringsAsFactors = FALSE
  )

  DBI::dbExecute(con, "BEGIN TRANSACTION;")
  tryCatch({
    DBI::dbWriteTable(con, "stg_tags", stg, overwrite = TRUE)
    DBI::dbExecute(con, "
      UPDATE papers AS p
      SET tag = s.tag
      FROM stg_tags AS s
      WHERE p.paper_id = s.paper_id
        AND s.tag IS NOT NULL
        AND trim(s.tag) <> ''
    ")
    DBI::dbExecute(con, "DROP TABLE IF EXISTS stg_tags;")
    DBI::dbExecute(con, "COMMIT;")
  }, error = function(e) {
    DBI::dbExecute(con, "ROLLBACK;")
    stop(".update_tags failed: ", conditionMessage(e))
  })

  invisible(NULL)
}

#' @noRd
.load_existing_ids <- function(db_path = NULL) {
  if (is.null(db_path)) db_path <- .cyberarxiv_db_path()
  if (!file.exists(db_path)) return(character(0))

  con <- tryCatch(
    DBI::dbConnect(duckdb::duckdb(), dbdir = db_path, read_only = TRUE),
    error = function(e) NULL
  )
  if (is.null(con)) return(character(0))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  .cyberarxiv_ensure_duckdb_extensions(con)

  if (!("papers" %in% DBI::dbListTables(con))) return(character(0))

  DBI::dbGetQuery(con, "SELECT paper_id FROM papers")$paper_id
}
