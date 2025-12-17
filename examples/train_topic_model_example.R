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

# Step 2: Assign topic labels to papers automatically
# The assign_topics function uses keyword matching to assign one of 10 IS topics
papers <- assign_topics(papers)

# Step 3: Train the model
cat("\n=== Training Topic Classification Model ===\n")

model_result <- train_topic_model(
  data = papers,
  test_split = 0.2,      # 20% for testing
  max_features = 5000,   # Maximum TF-IDF features
  ngram_max = 2,         # Use unigrams and bigrams
  seed = 42              # For reproducibility
)

# Step 4: View results
cat("\n=== Model Performance ===\n")
cat("Training accuracy:", round(model_result$metrics$train_accuracy * 100, 2), "%\n")
cat("Test accuracy:", round(model_result$metrics$test_accuracy * 100, 2), "%\n")
cat("Number of features:", model_result$metrics$n_features, "\n")
cat("Number of labels:", model_result$metrics$n_labels, "\n")

cat("\n=== Confusion Matrix ===\n")
print(model_result$confusion_matrix)

# Step 5: Save the trained model
cat("\n=== Saving Model ===\n")
save_topic_model(model_result, filename = "cybersecurity_topic_model.rds")

# Step 6: Test predictions on new data
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

# Step 7: Load model later (demonstration)
cat("\n=== Loading Saved Model ===\n")
loaded_model <- load_topic_model(filename = "cybersecurity_topic_model.rds")
cat("Model loaded successfully!\n")

cat("\n=== Example Complete ===\n")
cat("You can now use the trained model to classify new papers.\n")