#' Train topic classification model for cybersecurity papers
#'
#' Trains a multinomial logistic regression model to classify papers into 10 topic labels
#' related to Information Security. Uses TF-IDF features from title and abstract.
#'
#' @param data A data.frame with columns: title, abstract, topic_label
#' @param test_split Proportion of data to use for testing (default: 0.2)
#' @param max_features Maximum number of TF-IDF features (default: 5000)
#' @param ngram_max Maximum n-gram size (default: 2 for bigrams)
#' @param seed Random seed for reproducibility (default: 42)
#'
#' @return A list containing:
#'   \itemize{
#'     \item model: Trained glmnet model
#'     \item vectorizer: text2vec vectorizer for transforming new data
#'     \item tfidf: TF-IDF model
#'     \item label_mapping: Mapping between numeric and text labels
#'     \item metrics: Training and test accuracy
#'     \item confusion_matrix: Confusion matrix on test set
#'   }
#' @export
#'
#' @examples
#' \dontrun{
#' # Prepare data with topic labels
#' papers <- load_raw_data()
#' papers$topic_label <- sample(c("Malware", "Network Security", "Cryptography",
#'                                 "Authentication", "Privacy", "Intrusion Detection",
#'                                 "Vulnerability", "Threat Intelligence",
#'                                 "Access Control", "Security Analytics"),
#'                               nrow(papers), replace = TRUE)
#' 
#' # Train model
#' model_result <- train_topic_model(papers)
#' 
#' # View metrics
#' print(model_result$metrics)
#' print(model_result$confusion_matrix)
#' }
train_topic_model <- function(data, 
                              test_split = 0.2, 
                              max_features = 5000,
                              ngram_max = 2,
                              seed = 42) {
  
  # Validate input
  if (!is.data.frame(data)) {
    stop("'data' must be a data.frame")
  }
  
  required_cols <- c("title", "abstract", "topic_label")
  missing_cols <- setdiff(required_cols, names(data))
  if (length(missing_cols) > 0) {
    stop("Missing required columns: ", paste(missing_cols, collapse = ", "))
  }
  
  if (nrow(data) == 0) {
    stop("Data frame is empty")
  }
  
  # Remove rows with missing values
  data <- data[complete.cases(data[, required_cols]), ]
  
  if (nrow(data) == 0) {
    stop("No complete cases found in data")
  }
  
  # Check number of unique labels
  unique_labels <- unique(data$topic_label)
  n_labels <- length(unique_labels)
  
  if (n_labels < 2) {
    stop("Need at least 2 unique topic labels, found: ", n_labels)
  }
  
  message("Training model with ", n_labels, " topic labels")
  message("Total samples: ", nrow(data))
  
  # Create label mapping
  label_mapping <- data.frame(
    numeric = seq_along(unique_labels),
    label = unique_labels,
    stringsAsFactors = FALSE
  )
  
  # Convert labels to numeric
  data$topic_numeric <- match(data$topic_label, label_mapping$label)
  
  # Combine title and abstract for text features
  data$text <- paste(data$title, data$abstract, sep = " ")
  
  # Preprocess text
  data$text <- tolower(data$text)
  data$text <- gsub("[^a-z0-9\\s]", " ", data$text)
  data$text <- gsub("\\s+", " ", data$text)
  data$text <- trimws(data$text)
  
  # Split into train and test
  set.seed(seed)
  n <- nrow(data)
  test_size <- floor(n * test_split)
  test_idx <- sample(seq_len(n), test_size)
  train_idx <- setdiff(seq_len(n), test_idx)
  
  train_data <- data[train_idx, ]
  test_data <- data[test_idx, ]
  
  message("Training samples: ", nrow(train_data))
  message("Test samples: ", nrow(test_data))
  
  # Create text2vec iterator
  train_tokens <- text2vec::itoken(train_data$text, 
                                   preprocessor = tolower,
                                   tokenizer = text2vec::word_tokenizer,
                                   ids = train_data$id,
                                   progressbar = FALSE)
  
  # Create vocabulary
  vocab <- text2vec::create_vocabulary(train_tokens, 
                                       ngram = c(1L, as.integer(ngram_max)))
  
  # Prune vocabulary
  vocab <- text2vec::prune_vocabulary(vocab, 
                                      term_count_min = 2,
                                      doc_proportion_max = 0.5,
                                      doc_proportion_min = 0.001)
  
  # Limit vocabulary size
  if (nrow(vocab) > max_features) {
    vocab <- vocab[order(-vocab$term_count), ][seq_len(max_features), ]
  }
  
  message("Vocabulary size: ", nrow(vocab))
  
  # Create vectorizer
  vectorizer <- text2vec::vocab_vectorizer(vocab)
  
  # Create DTM for training
  train_dtm <- text2vec::create_dtm(train_tokens, vectorizer)
  
  # Fit TF-IDF
  tfidf_model <- text2vec::TfIdf$new()
  train_tfidf <- text2vec::fit_transform(train_dtm, tfidf_model)
  
  # Train multinomial logistic regression with glmnet
  message("Training multinomial logistic regression model...")
  
  model <- glmnet::cv.glmnet(
    x = train_tfidf,
    y = as.factor(train_data$topic_numeric),
    family = "multinomial",
    alpha = 1,  # Lasso regularization
    nfolds = 5,
    type.measure = "class",
    parallel = FALSE
  )
  
  # Predictions on training set
  train_pred <- predict(model, 
                       newx = train_tfidf, 
                       s = "lambda.min", 
                       type = "class")
  train_accuracy <- mean(train_pred == train_data$topic_numeric)
  
  # Transform test data
  test_tokens <- text2vec::itoken(test_data$text,
                                  preprocessor = tolower,
                                  tokenizer = text2vec::word_tokenizer,
                                  ids = test_data$id,
                                  progressbar = FALSE)
  
  test_dtm <- text2vec::create_dtm(test_tokens, vectorizer)
  test_tfidf <- text2vec::transform(test_dtm, tfidf_model)
  
  # Predictions on test set
  test_pred <- predict(model, 
                      newx = test_tfidf, 
                      s = "lambda.min", 
                      type = "class")
  test_accuracy <- mean(test_pred == test_data$topic_numeric)
  
  # Create confusion matrix
  conf_matrix <- table(
    Predicted = label_mapping$label[as.integer(test_pred)],
    Actual = test_data$topic_label
  )
  
  message("Training accuracy: ", round(train_accuracy * 100, 2), "%")
  message("Test accuracy: ", round(test_accuracy * 100, 2), "%")
  
  # Return model and metadata
  result <- list(
    model = model,
    vectorizer = vectorizer,
    tfidf = tfidf_model,
    label_mapping = label_mapping,
    metrics = list(
      train_accuracy = train_accuracy,
      test_accuracy = test_accuracy,
      n_features = nrow(vocab),
      n_labels = n_labels,
      train_samples = nrow(train_data),
      test_samples = nrow(test_data)
    ),
    confusion_matrix = conf_matrix
  )
  
  class(result) <- c("topic_model", "list")
  result
}

#' Predict topic labels for new papers
#'
#' Uses a trained topic model to predict labels for new papers
#'
#' @param model_result Output from train_topic_model()
#' @param data A data.frame with columns: title, abstract
#'
#' @return A data.frame with original data plus predicted_topic and predicted_prob columns
#' @export
#'
#' @examples
#' \dontrun{
#' # Train model
#' model_result <- train_topic_model(papers)
#' 
#' # Predict on new data
#' new_papers <- get_arxiv_papers(max_results = 10)
#' predictions <- predict_topic(model_result, new_papers)
#' }
predict_topic <- function(model_result, data) {
  
  if (!inherits(model_result, "topic_model")) {
    stop("'model_result' must be output from train_topic_model()")
  }
  
  if (!is.data.frame(data)) {
    stop("'data' must be a data.frame")
  }
  
  required_cols <- c("title", "abstract")
  missing_cols <- setdiff(required_cols, names(data))
  if (length(missing_cols) > 0) {
    stop("Missing required columns: ", paste(missing_cols, collapse = ", "))
  }
  
  if (nrow(data) == 0) {
    warning("Empty data frame provided")
    return(data)
  }
  
  # Combine title and abstract
  data$text <- paste(data$title, data$abstract, sep = " ")
  
  # Preprocess text
  data$text <- tolower(data$text)
  data$text <- gsub("[^a-z0-9\\s]", " ", data$text)
  data$text <- gsub("\\s+", " ", data$text)
  data$text <- trimws(data$text)
  
  # Create tokens
  tokens <- text2vec::itoken(data$text,
                             preprocessor = tolower,
                             tokenizer = text2vec::word_tokenizer,
                             progressbar = FALSE)
  
  # Create DTM
  dtm <- text2vec::create_dtm(tokens, model_result$vectorizer)
  
  # Transform with TF-IDF
  tfidf <- text2vec::transform(dtm, model_result$tfidf)
  
  # Predict classes
  pred_numeric <- predict(model_result$model,
                         newx = tfidf,
                         s = "lambda.min",
                         type = "class")
  
  # Predict probabilities
  pred_probs <- predict(model_result$model,
                       newx = tfidf,
                       s = "lambda.min",
                       type = "response")
  
  # Get max probability for each prediction
  max_probs <- apply(pred_probs, 1, max)
  
  # Map numeric predictions to labels
  pred_labels <- model_result$label_mapping$label[as.integer(pred_numeric)]
  
  # Add predictions to data
  data$predicted_topic <- pred_labels
  data$predicted_prob <- max_probs
  
  # Remove temporary text column
  data$text <- NULL
  
  data
}

#' Save trained topic model to disk
#'
#' @param model_result Output from train_topic_model()
#' @param filename Name of the RDS file (default: "topic_model.rds")
#' @param dir Directory to save the file (default: "models")
#'
#' @return Invisibly returns the file path
#' @export
save_topic_model <- function(model_result, filename = "topic_model.rds", dir = "models") {
  
  if (!inherits(model_result, "topic_model")) {
    stop("'model_result' must be output from train_topic_model()")
  }
  
  if (!dir.exists(dir)) {
    dir.create(dir, recursive = TRUE)
  }
  
  filepath <- file.path(dir, filename)
  saveRDS(model_result, file = filepath)
  
  message("Model saved to: ", filepath)
  invisible(filepath)
}

#' Load trained topic model from disk
#'
#' @param filename Name of the RDS file (default: "topic_model.rds")
#' @param dir Directory containing the file (default: "models")
#'
#' @return Loaded topic model object
#' @export
load_topic_model <- function(filename = "topic_model.rds", dir = "models") {
  
  filepath <- file.path(dir, filename)
  
  if (!file.exists(filepath)) {
    stop("File '", filepath, "' not found")
  }
  
  model_result <- readRDS(filepath)
  
  if (!inherits(model_result, "topic_model")) {
    stop("Loaded object is not a valid topic_model")
  }
  
  message("Model loaded from: ", filepath)
  model_result
}