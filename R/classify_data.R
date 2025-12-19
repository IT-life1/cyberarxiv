#' Search papers
#' @param data dataframe from load_raw_data()
#' @param query text to search
#' @param year year filter (optional)
#'
#' @return filtered dataframe
#' @export
search_papers <- function(data, query = NULL, year = NULL) {
  
  if (nrow(data) == 0) return(data)
  
  result <- data
  
  if (!is.null(query)) {
    query <- tolower(query)
    title_match <- grepl(query, tolower(data$title))
    abstract_match <- grepl(query, tolower(data$abstract))
    result <- data[title_match | abstract_match, ]
  }
  
  if (!is.null(year)) {
    years <- as.integer(format(as.POSIXct(result$published_date), "%Y"))
    result <- result[years == year, ]
  }
  
  rownames(result) <- NULL
  result
}

#' Classify data
#' @param data dataframe from load_raw_data()
#'
#' @return list with statistics
#' @export
classify_data <- function(data) {
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
  
  tag_keywords <- list(
    
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
    )
    ,
    
    
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
)
  
  extended_stopwords <- function() {
    c(
      "the", "and", "of", "in", "to", "a", "is", "that", "for", "on", 
      "with", "as", "by", "this", "we", "are", "it", "not", "be", "at",
      "from", "or", "an", "but", "which", "you", "have", "has", "had",
      "was", "were", "will", "would", "can", "could", "if", "then",
      "else", "when", "where", "how", "why", "what", "who", "whom",
      "such", "than", "that", "these", "those", "they", "them", "their",
      "there", "therefore", "thus", "so", "also", "just", "only", "more",
      "most", "many", "much", "some", "any", "each", "every", "no",
      "other", "another", "same", "even", "very", "too", "always",
      "often", "sometimes", "never", "again", "please", "may", "might",
      "must", "should", "shall", "let", "like", "likes", "liked",
      "about", "above", "below", "between", "since", "until", "upon",
      "while", "without", "within", "yet", "your", "yours", "our", "ours",
      "paper", "study", "research", "article", "result", "method",
      "approach", "analysis", "data", "model", "system", "problem",
      "solution", "propose", "show", "demonstrate", "investigate",
      "examine", "present", "discuss", "conclude", "suggest",
      "however", "therefore", "moreover", "furthermore", "nevertheless",
      "thus", "hence", "consequently", "additionally", "similarly"
    )
  }
  
  preprocess_abstracts <- function(texts) {
    texts <- tolower(texts)
    texts <- str_remove_all(texts, "<.*?>")
    texts <- str_remove_all(texts, "[^[:alnum:]\\s-]")
    texts <- str_remove_all(texts, "\\b\\w\\b")
    texts <- str_remove_all(texts, "\\b\\d+\\b")
    texts <- str_squish(texts)
    
    stop_words <- extended_stopwords()
    pattern <- paste0("\\b(", paste(stop_words, collapse = "|"), ")\\b")
    texts <- str_remove_all(texts, pattern)
    
    return(texts)
  }
  
  classify_by_keywords <- function(abstract) {
    if (is.na(abstract) || abstract == "") {
      return("other")
    }
    
    abstract_lower <- tolower(abstract)
    scores <- numeric(length(predefined_tags) - 1)  # without "other"
    names(scores) <- predefined_tags[1:(length(predefined_tags)-1)]
    
    for (tag_name in names(scores)) {
      keywords <- tag_keywords[[tag_name]]
      keyword_count <- 0
      
      for (keyword in keywords) {
        if (grepl(paste0("\\b", keyword, "\\b"), abstract_lower, ignore.case = TRUE)) {
          keyword_count <- keyword_count + nchar(keyword) * 0.1
        }
      }
      
      scores[tag_name] <- keyword_count
    }
    
    max_score <- max(scores)
    if (max_score > 0) {
      top_tags <- names(scores[scores == max_score])
      if (length(top_tags) > 1) {
        return(top_tags[1])
      } else {
        return(top_tags)
      }
    } else {
      return("other")
    }
  }
  
  tag_with_lda_and_classify <- function(texts, data) {
    keyword_tags <- sapply(data$abstract, classify_by_keywords)
    
    return(keyword_tags)
  }
  
  create_topic_tags <- function(data) {
    if (!"abstract" %in% names(data)) {
      stop("Column 'abstract' is missing from data")
    }
    
    data$tag <- sapply(data$abstract, classify_by_keywords)
    
    tag_stats <- data %>%
      count(tag, sort = TRUE) %>%
      mutate(percentage = round(n / nrow(data) * 100, 1))
    
    
    return(data)
  }
  
  return(create_topic_tags(data))
}

#' ETL
#'
#' Pipeline that fetches papers from arXiv API (Atom) converts it by classifing and updates database.
#'
#' @param max_results How many papers to load (integer).
#'
#' @export
etl <- function(_max_results) {
  save_raw_data(get_arxiv_papers(max_results = _max_results))
  data <- load_raw_data()
  papers <- classify_data(data)
  save_publications(papers)
}