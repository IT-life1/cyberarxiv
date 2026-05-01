# ============================================================
# CyberArXiv ML Classification Service
# BertClassifier (DistilBERT-base-uncased) + FastAPI
# ============================================================
FROM python:3.11-slim

WORKDIR /srv/cyberarxiv-ml

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first for better Docker layer caching
COPY ml_service/requirements.txt /srv/cyberarxiv-ml/requirements.txt

RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY ml_service/app.py /srv/cyberarxiv-ml/app.py
COPY ml_service/train_model.py /srv/cyberarxiv-ml/train_model.py
COPY ml_service/arxiv_classifier.py /srv/cyberarxiv-ml/arxiv_classifier.py
COPY ml_service/training_pipeline /srv/cyberarxiv-ml/training_pipeline

# Create directories for model weights and training artifacts
RUN mkdir -p /srv/cyberarxiv-ml/models /srv/cyberarxiv-ml/training_data

# Default model path - mount your .pt file here as a volume:
#   docker run -v /path/to/best_model.pt:/srv/cyberarxiv-ml/models/model.pt ...
ENV MODEL_PATH=/srv/cyberarxiv-ml/models/model.pt
ENV ML_SERVICE_PORT=5001
ENV TRAINING_DATA_DIR=/srv/cyberarxiv-ml/training_data
ENV MODELS_DIR=/srv/cyberarxiv-ml/models

EXPOSE 5001

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:5001/health')" || exit 1

CMD ["python", "-m", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "5001"]
