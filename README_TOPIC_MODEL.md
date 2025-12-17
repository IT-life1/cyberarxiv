# Topic Classification Model for Cybersecurity Papers

This document describes the topic classification functionality added to the `cyberarxiv` package.

## Overview

The package now includes functions to train and use a machine learning model that classifies cybersecurity papers into 10 topic categories related to Information Security.

## Features

- **Text Classification**: Uses TF-IDF features and multinomial logistic regression
- **10 Topic Categories**: Covers major areas of Information Security
- **Easy to Use**: Simple API for training, predicting, and saving models
- **Reproducible**: Seed-based random state for consistent results

## Topic Categories

The model is designed to classify papers into these 10 Information Security topics:

1. **Malware Analysis** - Malware, trojans, ransomware, viruses
2. **Network Security** - Network attacks, DDoS, firewalls, routing
3. **Cryptography** - Encryption, cryptographic protocols, hashing
4. **Authentication** - Identity verification, biometrics, passwords
5. **Privacy** - Data privacy, anonymity, GDPR compliance
6. **Intrusion Detection** - IDS/IPS, anomaly detection
7. **Vulnerability Analysis** - Software vulnerabilities, exploits, CVEs
8. **Threat Intelligence** - Threat hunting, APTs, adversaries
9. **Access Control** - Authorization, permissions, RBAC
10. **Security Analytics** - Security monitoring, SIEM, analytics

## Installation

Make sure you have the required dependencies:

```r
install.packages(c("text2vec", "glmnet"))
```

## Usage

### 1. Prepare Your Data

Your data must have three columns:
- `title`: Paper title
- `abstract`: Paper abstract
- `topic_label`: One of the 10 topic categories

```r
library(cyberarxiv)

# Load papers
papers <- load_raw_data()

# Assign topic labels (you need labeled data for training)
papers$topic_label <- c("Malware Analysis", "Network Security", ...)
```

### 2. Train the Model

```r
# Train model with default parameters
model_result <- train_topic_model(papers)

# Or customize parameters
model_result <- train_topic_model(
  data = papers,
  test_split = 0.2,      # 20% for testing
  max_features = 5000,   # Maximum TF-IDF features
  ngram_max = 2,         # Use unigrams and bigrams
  seed = 42              # For reproducibility
)
```

### 3. View Model Performance

```r
# View metrics
print(model_result$metrics)
# $train_accuracy: Training set accuracy
# $test_accuracy: Test set accuracy
# $n_features: Number of features used
# $n_labels: Number of topic labels

# View confusion matrix
print(model_result$confusion_matrix)
```

### 4. Save the Model

```r
# Save to disk
save_topic_model(model_result, filename = "my_model.rds")
```

### 5. Load and Use the Model

```r
# Load saved model
model <- load_topic_model(filename = "my_model.rds")

# Get new papers
new_papers <- get_arxiv_papers(max_results = 10)

# Predict topics
predictions <- predict_topic(model, new_papers)

# View predictions
head(predictions[, c("title", "predicted_topic", "predicted_prob")])
```

## Model Architecture

The model uses:

1. **Text Preprocessing**:
   - Combines title and abstract
   - Converts to lowercase
   - Removes special characters
   - Tokenizes into words

2. **Feature Extraction**:
   - TF-IDF (Term Frequency-Inverse Document Frequency)
   - Unigrams and bigrams (configurable)
   - Vocabulary pruning to remove rare/common terms

3. **Classification**:
   - Multinomial logistic regression via `glmnet`
   - L1 regularization (Lasso)
   - Cross-validation for hyperparameter tuning

## Example Script

See [`examples/train_topic_model_example.R`](examples/train_topic_model_example.R) for a complete working example.

## Function Reference

### `train_topic_model()`

Trains a topic classification model.

**Parameters:**
- `data`: Data frame with title, abstract, topic_label columns
- `test_split`: Proportion for test set (default: 0.2)
- `max_features`: Maximum TF-IDF features (default: 5000)
- `ngram_max`: Maximum n-gram size (default: 2)
- `seed`: Random seed (default: 42)

**Returns:** List with model, vectorizer, tfidf, label_mapping, metrics, confusion_matrix

### `predict_topic()`

Predicts topic labels for new papers.

**Parameters:**
- `model_result`: Output from `train_topic_model()`
- `data`: Data frame with title and abstract columns

**Returns:** Data frame with predicted_topic and predicted_prob columns added

### `save_topic_model()`

Saves trained model to disk.

**Parameters:**
- `model_result`: Output from `train_topic_model()`
- `filename`: RDS filename (default: "topic_model.rds")
- `dir`: Directory (default: "models")

### `load_topic_model()`

Loads trained model from disk.

**Parameters:**
- `filename`: RDS filename (default: "topic_model.rds")
- `dir`: Directory (default: "models")

**Returns:** Loaded topic model object

## Tips for Better Results

1. **Quality Data**: Ensure your training data has accurate topic labels
2. **Balanced Classes**: Try to have similar numbers of papers per topic
3. **More Data**: More training examples generally improve accuracy
4. **Feature Tuning**: Experiment with `max_features` and `ngram_max`
5. **Validation**: Always check the confusion matrix to identify problem areas

## Troubleshooting

**Low accuracy?**
- Check if your topic labels are consistent
- Increase training data size
- Adjust `max_features` parameter
- Consider using trigrams (`ngram_max = 3`)

**Memory issues?**
- Reduce `max_features`
- Process data in batches
- Use a machine with more RAM

**Slow training?**
- Reduce `max_features`
- Reduce training data size
- Use fewer cross-validation folds

## License

MIT License - See LICENSE file for details