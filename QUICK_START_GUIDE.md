# Быстрый старт (готовые образы)

Запустите cyberarxiv с помощью готовых Docker-образов из GitHub Container Registry — сборка не требуется.

## Предварительные требования

- Установленные Docker и Docker Compose
- ~15 ГБ свободного места на диске (для ML-образа)

## 1. Загрузите образы

```bash
docker pull ghcr.io/it-life1/cyberarxiv:latest
docker pull ghcr.io/it-life1/cyberarxiv-ml:latest
docker pull ghcr.io/it-life1/cyberarxiv-mcp:latest
```

## 2. Создайте рабочую директорию

```bash
mkdir cyberarxiv && cd cyberarxiv
mkdir -p data raw-data training_data models mlflow site
```

## 3. Создайте `docker-compose.yml`

Сохраните этот файл в рабочей директории:

```yaml
services:
  # ============================================================
  # Сервис R-пакета + Дашборд
  # ============================================================
  cyberarxiv:
    image: ghcr.io/it-life1/cyberarxiv:latest
    container_name: cyberarxiv
    restart: unless-stopped
    environment:
      - MAX_RESULTS=1000
      - QUERY=
      - CYBERARXIV_DB_PATH=/srv/cyberarxiv/data/cyberarxiv.duckdb
      - ML_SERVICE_URL=http://cyberarxiv-ml:5001
      - MLFLOW_UI_URL=http://localhost:5000
      # Опционально: ключ для коллектора CORE (https://core.ac.uk/services/api).
      # Если оставить пустым — CORE-источник будет выдавать 401, остальные работают.
      - CORE_API_KEY=${CORE_API_KEY:-}
    ports:
      - "8000:8000"
      - "3838:3838"
    volumes:
      - ./data:/srv/cyberarxiv/data
      - ./raw-data:/srv/cyberarxiv/raw-data
      - ./site:/var/www/html
      - ./training_data:/srv/cyberarxiv/training_data
    depends_on:
      cyberarxiv-ml:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3838"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

  # ============================================================
  # Сервис ML-классификации (PyTorch + MLflow)
  # ============================================================
  cyberarxiv-ml:
    image: ghcr.io/it-life1/cyberarxiv-ml:latest
    container_name: cyberarxiv-ml
    restart: unless-stopped
    environment:
      - MODEL_PATH=/srv/cyberarxiv-ml/models/model.pt
      - ML_SERVICE_PORT=5001
      - MLFLOW_TRACKING_URI=http://cyberarxiv-mlflow:5000
      - TRAINING_DATA_DIR=/srv/cyberarxiv-ml/training_data
      - MODELS_DIR=/srv/cyberarxiv-ml/models
      # LLM-настройки берутся из training_data/config.json (UI).
      # Эти env-переменные оставлены пустыми, чтобы выбор провайдера в UI
      # действительно применялся. Чтобы переопределить из хоста — экспортируйте
      # LLM_PROVIDER / LLM_MODEL / LLM_API_KEY / LLM_BASE_URL перед `docker compose up`.
      - LLM_PROVIDER=${LLM_PROVIDER:-}
      - LLM_MODEL=${LLM_MODEL:-}
      - LLM_API_KEY=${LLM_API_KEY:-}
      - LLM_BASE_URL=${LLM_BASE_URL:-}
    ports:
      - "5001:5001"
    volumes:
      - ./models:/srv/cyberarxiv-ml/models
      - ./training_data:/srv/cyberarxiv-ml/training_data
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:5001/health')"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 120s

  # ============================================================
  # Сервер отслеживания MLflow
  # ============================================================
  cyberarxiv-mlflow:
    image: python:3.11-slim
    container_name: cyberarxiv-mlflow
    restart: unless-stopped
    environment:
      - MLFLOW_BACKEND_STORE_URI=sqlite:///mlflow/mlflow.db
      - MLFLOW_DEFAULT_ARTIFACT_ROOT=/mlflow/artifacts
    ports:
      - "5000:5000"
    volumes:
      - ./mlflow:/mlflow
    command: bash -c "pip install --no-cache-dir 'mlflow<3.0' && mlflow server --backend-store-uri sqlite:///mlflow/mlflow.db --default-artifact-root /mlflow/artifacts --host 0.0.0.0 --port 5000"
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:5000/health')"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s

  # ============================================================
  # MCP-сервер (интерфейс AI-ассистента)
  # ============================================================
  cyberarxiv-mcp:
    image: ghcr.io/it-life1/cyberarxiv-mcp:latest
    container_name: cyberarxiv-mcp
    restart: unless-stopped
    environment:
      - CYBERARXIV_DB_PATH=/data/cyberarxiv.duckdb
      - ML_SERVICE_URL=http://cyberarxiv-ml:5001
      - ML_DEFAULT_MODEL=best_model
      # streamable-http транспорт: эндпоинт /mcp на MCP_PORT
      - MCP_TRANSPORT=streamable-http
      - MCP_HOST=0.0.0.0
      - MCP_PORT=5002
    ports:
      - "5002:5002"
    volumes:
      - ./data:/data
    depends_on:
      cyberarxiv-ml:
        condition: service_healthy
```

## 4. Запустите всё

При необходимости экспортируйте секреты перед стартом (всё опционально):

```bash
export CORE_API_KEY=...          # ключ для коллектора CORE (core.ac.uk)
export LLM_API_KEY=sk-...        # если хотите задать LLM-ключ через env, а не UI
docker compose up -d
```

Или просто:

```bash
docker compose up -d
```

```bash
docker compose logs -f cyberarxiv
```

Данные сохраняются в `./data`, `./mlflow`, `./models` и `./training_data`.

## 5. Доступ к сервисам

| Сервис | URL |
|--------|-----|
| Shiny-приложение | http://localhost:3838 |
| ML API | http://localhost:5001 |
| MLflow UI | http://localhost:5000 |
| MCP-сервер (streamable-http) | http://localhost:5002/mcp |

## Обновление до последних образов

```bash
docker compose pull
docker compose up -d
```
