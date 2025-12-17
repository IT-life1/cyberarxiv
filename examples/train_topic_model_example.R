# Example: Training a Topic Classification Model for Cybersecurity Papers
# This script demonstrates how to use the train_topic_model function

library(cyberarxiv)

# Step 1: Load existing papers data
# If you don't have data yet, fetch some papers first:
# papers <- get_arxiv_papers(max_results = 500)
# save_raw_data(papers)

papers <- load_raw_data()

if (nrow(papers) == 0) {
  stop("No papers found. Please fetch papers first using get_arxiv_papers()")
}

cat("Loaded", nrow(papers), "papers\n")

# Step 2: Define 10 Information Security topic labels
# These are common cybersecurity topics
topic_labels <- c(
  "Malware Analysis",           # Malware, trojans, ransomware
  "Network Security",            # Network attacks, DDoS, firewalls
  "Cryptography",                # Encryption, cryptographic protocols
  "Authentication",              # Identity verification, biometrics
  "Privacy",                     # Data privacy, anonymity
  "Intrusion Detection",         # IDS, anomaly detection
  "Vulnerability Analysis",      # Software vulnerabilities, exploits
  "Threat Intelligence",         # Threat hunting, APTs
  "Access Control",              # Authorization, permissions
  "Security Analytics"           # Security monitoring, SIEM
)

# Step 3: Assign topic labels to papers
# In a real scenario, you would have labeled data
# For demonstration, we'll assign labels based on keywords in abstracts

assign_topic <- function(abstract) {
  abstract_lower <- tolower(abstract)
  
  if (grepl("malware|trojan|ransomware|virus|worm", abstract_lower)) {
    return("Malware Analysis")
  } else if (grepl("network|ddos|firewall|router|packet", abstract_lower)) {
    return("Network Security")
  } else if (grepl("cryptograph|encrypt|cipher|key|hash", abstract_lower)) {
    return("Cryptography")
  } else if (grepl("authenticat|biometric|password|credential", abstract_lower)) {
    return("Authentication")
  } else if (grepl("privacy|anonymous|gdpr|personal data", abstract_lower)) {
    return("Privacy")
  } else if (grepl("intrusion|ids|ips|anomaly detection", abstract_lower)) {
    return("Intrusion Detection")
  } else if (grepl("vulnerabilit|exploit|cve|patch|bug", abstract_lower)) {
    return("Vulnerability Analysis")
  } else if (grepl("threat|apt|intelligence|adversar", abstract_lower)) {
    return("Threat Intelligence")
  } else if (grepl("access control|authorization|permission|rbac", abstract_lower)) {
    return("Access Control")
  } else {
    return("Security Analytics")
  }
}

# Apply topic assignment
papers$topic_label <- sapply(papers$abstract, assign_topic)

# Check distribution of topics
cat("\nTopic distribution:\n")
print(table(papers$topic_label))

# Step 4: Train the model
cat("\n=== Training Topic Classification Model ===\n")

model_result <- train_topic_model(
  data = papers,
  test_split = 0.2,      # 20% for testing
  max_features = 5000,   # Maximum TF-IDF features
  ngram_max = 2,         # Use unigrams and bigrams
  seed = 42              # For reproducibility
)

# Step 5: View results
cat("\n=== Model Performance ===\n")
cat("Training accuracy:", round(model_result$metrics$train_accuracy * 100, 2), "%\n")
cat("Test accuracy:", round(model_result$metrics$test_accuracy * 100, 2), "%\n")
cat("Number of features:", model_result$metrics$n_features, "\n")
cat("Number of labels:", model_result$metrics$n_labels, "\n")

cat("\n=== Confusion Matrix ===\n")
print(model_result$confusion_matrix)

# Step 6: Save the trained model
cat("\n=== Saving Model ===\n")
save_topic_model(model_result, filename = "cybersecurity_topic_model.rds")

# Step 7: Test predictions on new data
cat("\n=== Testing Predictions ===\n")

# Fetch some new papers
new_papers <- get_arxiv_papers(max_results = 10)

if (nrow(new_papers) > 0) {
  # Predict topics
  predictions <- predict_topic(model_result, new_papers)
  
  # Display results
  cat("\nPredictions for new papers:\n")
  for (i in 1:min(5, nrow(predictions))) {
    cat("\n", i, ". ", predictions$title[i], "\n", sep = "")
    cat("   Predicted topic: ", predictions$predicted_topic[i], "\n", sep = "")
    cat("   Confidence: ", round(predictions$predicted_prob[i] * 100, 1), "%\n", sep = "")
  }
}

# Step 8: Load model later (demonstration)
cat("\n=== Loading Saved Model ===\n")
loaded_model <- load_topic_model(filename = "cybersecurity_topic_model.rds")
cat("Model loaded successfully!\n")

cat("\n=== Example Complete ===\n")
cat("You can now use the trained model to classify new papers.\n")