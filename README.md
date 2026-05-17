# cyberarxiv

R-пакет для автоматического сбора, классификации и визуализации научных статей по кибербезопасности с [arXiv](https://arxiv.org).

Пакет реализует полный ETL-пайплайн: загрузка статей через arXiv API → хранение в DuckDB → keyword-классификация → ML-классификация (DistilBERT) → интерактивный дашборд или Shiny GUI.

См. [Быстрый старт (Docker)](#быстрый-старт-docker) для запуска через `git clone && docker compose up` или [Локальная установка](#локальная-установка) для разработки.

---

## Содержание

- [Архитектура](#архитектура)
- [Структура проекта](#структура-проекта)
- [Быстрый старт (Docker)](#быстрый-старт-docker)
- [Локальная установка](#локальная-установка)
- [ETL-пайплайн](#etl-пайплайн)
- [Классификация статей](#классификация-статей)
- [ML-сервис](#ml-сервис)
- [Training Pipeline (GUI)](#training-pipeline-gui) ★ новое
- [Обучение модели (CLI)](#обучение-модели-cli)
- [Shiny GUI](#shiny-gui)
- [Схема базы данных](#схема-базы-данных)
- [Переменные окружения](#переменные-окружения)
- [Справочник функций](#справочник-функций)
- [Troubleshooting](#troubleshooting)

---

## Архитектура

Система состоит из трёх Docker-сервисов, которые взаимодействуют друг с другом:

```
┌─────────────────────────────────────────────────────────────────┐
│           arXiv · CORE · КиберЛенинка · LLM (OpenAI/             │
│                  Anthropic/xAI) — внешние API                   │
└──────────────┬──────────────────────────────┬───────────────────┘
               │ HTTP                         │ HTTPS
               ▼                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                  cyberarxiv  (порт 3838)                        │
│                                                                 │
│  R-пакет + Shiny GUI (7 вкладок)                                │
│  ─────────────────────────────────────────────────────────────  │
│  collect_all()       →  RDS (raw-data/) → DuckDB                │
│  classify_data()     →  keyword-теги                            │
│  classify_with_ml()  →  HTTP → cyberarxiv-ml /classify          │
│                                                                 │
│  training_*  ───────→  HTTP → cyberarxiv-ml /training/*         │
│    (collect / label / export_excel / train / jobs / files)      │
│                                                                 │
│  launch_app()                                                   │
└─────────────────────────┬───────────────────────────────────────┘
                          │ HTTP (порт 5001)
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│               cyberarxiv-ml  (порт 5001)                        │
│                                                                 │
│  Python 3.11 · FastAPI · PyTorch · DistilBERT-base-uncased      │
│  ─────────────────────────────────────────────────────────────  │
│  Inference:                                                     │
│   POST /classify        — пакетная классификация                │
│   POST /classify_single — одна аннотация                        │
│   GET  /health  /models /model_info                             │
│   POST /reload_models   — горячая перезагрузка .pt              │
│                                                                 │
│  Training pipeline (training_pipeline/*):                       │
│   GET/POST /training/config         — таксономия + промпты + LLM│
│   POST     /training/collect        — сбор arXiv (job)          │
│   POST     /training/label          — LLM-разметка (job)        │
│   POST     /training/export_excel   — labeled.parquet → .xlsx   │
│   POST     /training/train          → subprocess train_model.py │
│   GET      /training/jobs[/{id}]    — статус и лог job-ов       │
│   GET      /training/files/{cat}    — артефакты в training_data/│
│   GET      /training/health         — диагностика пайплайна     │
└─────────────────────────┬───────────────────────────────────────┘
                          │ HTTP (порт 5000)
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│              cyberarxiv-mlflow  (порт 5000)                     │
│                                                                 │
│  MLflow Tracking Server · SQLite backend                        │
│  Хранит параметры, метрики и .pt-артефакты каждого run          │
└─────────────────────────────────────────────────────────────────┘
```

### Порядок запуска (docker-compose)

Docker Compose поднимает сервисы в правильном порядке:
1. `cyberarxiv-mlflow` — стартует первым (MLflow не обязателен, но запускается раньше)
2. `cyberarxiv-ml` — ждёт healthy-check перед стартом основного сервиса
3. `cyberarxiv` — стартует только после того, как ML-сервис здоров; запускает ETL и поднимает UI

---

## Структура проекта

```
cyberarxiv/
├── R/                          # Исходный код R-пакета
│   ├── collector_registry.R    # Реестр коллекторов (YAML-driven)
│   ├── fetch_feed.R            # atom/rss/oai_pmh/core_api/r_script
│   ├── get_arxiv_papers.R      # Backwards-compat wrapper
│   ├── raw_data.R              # Сохранение/загрузка RDS (raw-слой)
│   ├── classify_data.R         # Keyword-классификатор + ETL-пайплайн
│   ├── save_publications.R     # Upsert в DuckDB + маппинг категорий
│   ├── load_publications.R     # Чтение из DuckDB с фильтрами
│   ├── db.R                    # Подключение к DuckDB + инициализация схемы
│   ├── mlflow_client.R         # Клиент инференса + update_ml_tags()
│   ├── training_client.R       # Клиент training-pipeline (config/collect/label/train)
│   ├── shiny_app.R             # Shiny GUI (7 вкладок, включая Обучение)
│   ├── text_utils.R            # Топ-слова по аннотациям
│   ├── cyberarxiv_data.R       # Документация встроенного датасета
│   └── zzz.R                   # .onLoad / .onAttach хуки
│
├── ml_service/                 # Python ML-сервис
│   ├── app.py                  # FastAPI-приложение + BertClassifier
│   ├── arxiv_classifier.py     # Датасет, DataLoader, архитектура модели
│   ├── train_model.py          # Скрипт обучения (CLI; запускается как subprocess)
│   ├── training_pipeline/      # Python-пакет: GUI-driven training pipeline
│   │   ├── paths.py            # Каскадный резолвер base-директории
│   │   ├── config_store.py     # Persistent config: classes/prompts/LLM keys
│   │   ├── job_store.py        # File-backed job tracker (выживает рестарт)
│   │   ├── data_collector.py   # arXiv Atom → parquet
│   │   ├── llm_labeler.py      # OpenAI/Anthropic/xAI Grok → labels
│   │   ├── excel_export.py     # parquet ↔ xlsx ↔ training CSV
│   │   ├── train_runner.py     # Subprocess wrapper для train_model.py
│   │   └── pipeline.py         # Оркестратор для FastAPI BackgroundTasks
│   └── requirements.txt        # fastapi, torch, openai, anthropic, openpyxl, …
│
├── inst/                       # Установленные ресурсы пакета
│   ├── collectors/             # YAML-спеки коллекторов (см. inst/collectors/README.md)
│   ├── keywords.yml            # English keyword-таксономия
│   ├── keywords_ru.yml         # Russian keyword-таксономия
│   └── ml_tasks.yml            # Маппинг task → {lang: model_name}
│
├── training_data/              # Артефакты GUI-пайплайна (маунт в оба контейнера)
│   ├── raw/                    # arxiv_*.parquet (сырые)
│   ├── labeled/                # labeled_*.parquet (после LLM)
│   ├── excel/                  # *.xlsx (для ручной правки)
│   ├── training_csv/           # CSV для train_model.py
│   ├── jobs/                   # JSON со статусом каждого job
│   └── config/training_config.json  # Классы, промпты, LLM creds
│
├── models/                     # *.pt чекпойнты (читает инференс-сервис)
├── mlflow/                     # SQLite-БД MLflow + artifacts
├── docker/                     # Скрипты запуска R-контейнера
├── data/                       # DuckDB БД, raw RDS, встроенный датасет
├── man/                        # Документация (roxygen2 .Rd)
├── Dockerfile                  # R-сервис (rocker/r-ver:4.3.2)
├── Dockerfile.ml               # ML-сервис (python:3.11-slim)
├── docker-compose.yml          # Оркестрация трёх сервисов
├── DESCRIPTION                 # Метаданные R-пакета
├── NAMESPACE                   # Экспорты (генерируется roxygen2)
└── renv.lock                   # Зафиксированные версии R-пакетов
```

---

## Быстрый старт (Docker)

Готовые образы публикуются в [GitHub Container Registry](https://github.com/IT-life1/cyberarxiv/pkgs/container/cyberarxiv) по каждому push в `main` (см. `.github/workflows/docker-build.yml`). Локальной сборки не требуется.

### Требования

- Docker ≥ 24.0 и Docker Compose ≥ 2.20
- ~15 ГБ свободного места под образ `cyberarxiv-ml` (PyTorch)

### Запуск

```bash
git clone https://github.com/IT-life1/cyberarxiv.git
cd cyberarxiv
docker compose up -d
```

`docker compose` автоматически подтянет три образа из `ghcr.io/it-life1/*:latest` — они прописаны в `docker-compose.yml`. Первый старт `cyberarxiv` может занять до 5 минут, пока R-пакет прогревает кэш и проходят healthcheck'и.

После старта доступны:

| Сервис | URL | Описание |
|---|---|---|
| Shiny GUI | http://localhost:3838 | Интерактивный дашборд (7 вкладок) |
| ML API | http://localhost:5001 | REST API классификатора |
| MLflow UI | http://localhost:5000 | Трекинг экспериментов |
| MCP-сервер | http://localhost:5002/mcp | Для Claude.ai / Cursor (streamable-http) |

Данные сохраняются в bind-mount директории: `./data`, `./raw-data`, `./training_data`, `./models`, `./mlflow`. Все они создаются автоматически при первом запуске.

### Опциональные секреты

```bash
# Ключ для коллектора CORE (https://core.ac.uk/services/api)
export CORE_API_KEY=...

# Если хотите задать LLM-провайдер из env, а не из UI (training_data/config.json)
export LLM_PROVIDER=openai LLM_API_KEY=sk-...

docker compose up -d
```

### ML-модели

Чтобы `cyberarxiv-ml` мог классифицировать статьи, в `./models/` должны лежать `.pt`-файлы. Можно либо обучить их через UI (вкладка Training), либо скачать готовые из релизов репозитория и положить в `./models/` до `docker compose up`.

### Обновление до свежей версии

```bash
git pull
docker compose pull
docker compose up -d
```

### Параметры ETL

```bash
# Скачать 500 статей с кастомным запросом
MAX_RESULTS=500 QUERY="cat:cs.CR AND all:ransomware" docker compose up
```

### Локальная сборка (для разработки)

Если правите Dockerfile или хотите запустить изменения до их публикации в GHCR:

```bash
docker compose up --build
```

В `docker-compose.yml` рядом с `image:` сохранены `build:` блоки именно для этого сценария.

---

## Локальная установка

### Требования

- R ≥ 4.3
- Python ≥ 3.10 (для ML-сервиса и training-pipeline)
- ~3 GB свободного места (PyTorch + transformers + DistilBERT)

### Установка R-пакета

```r
# Из директории проекта
install.packages("pak")
pak::local_install(".", dependencies = TRUE)

# Или через devtools
devtools::install_local(".")
```

### Установка Python-зависимостей

```bash
cd ml_service
python3.10 -m pip install --user -r requirements.txt
# Или в venv:
python3.10 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt
```

В составе: `fastapi`, `uvicorn`, `torch`, `transformers`, `mlflow`, `openai`, `anthropic`, `openpyxl`, `pyarrow`, `requests`. Без `openai`/`anthropic` LLM-разметка не работает; без `openpyxl`/`pyarrow` падает Excel-экспорт.

### Запуск сервисов локально (без Docker)

```bash
# 1. ML-сервис на :5001
cd "$(pwd)/ml_service"
TRAINING_DATA_DIR="$(cd .. && pwd)/training_data" \
MODELS_DIR="$(cd .. && pwd)/models" \
MLFLOW_TRACKING_URI=http://localhost:5000 \
python3.10 -m uvicorn app:app --host 0.0.0.0 --port 5001

# 2. MLflow-сервер на :5000 (в отдельном терминале)
cd <project_root>
mkdir -p mlflow/artifacts
mlflow server \
  --backend-store-uri "sqlite:///$(pwd)/mlflow/mlflow.db" \
  --default-artifact-root "file://$(pwd)/mlflow/artifacts" \
  --host 127.0.0.1 --port 5000

# 3. Shiny GUI на :3838 (R)
R -e 'library(cyberarxiv); launch_app(host="127.0.0.1", port=3838, launch_browser=FALSE)'
```

### Проверка установки

```r
library(cyberarxiv)
data(cyberarxiv_data)
head(cyberarxiv_data)

# Health-check всего пайплайна:
ml_service_is_healthy()                          # TRUE
training_get_config()                            # см. сохранённые классы и LLM
```

---

## ETL-пайплайн

### Основная функция `etl()`

Пайплайн следует паттерну **fetch → RDS → DB → classify → update tags**:

```
arXiv API
    ↓ get_arxiv_papers()
RDS (raw-data/arxiv_papers.rds)
    ↓ save_publications() с пустыми тегами
DuckDB (papers table)
    ↓ classify_data()
classify_data() — классификация в памяти
    ↓ .update_tags()
DuckDB — UPDATE tag WHERE paper_id IN (...)
```

Этот порядок гарантирует, что **данные не теряются при сбое классификатора**: статьи оседают в БД с пустым тегом до начала классификации. Перезапустить классификацию можно без повторного обращения к arXiv.

### Стандартный ETL

```r
library(cyberarxiv)

# Скачать 100 статей (по умолчанию)
etl()

# Скачать 500 статей
etl(max_results = 500)

# Указать путь к БД явно
etl(max_results = 200, db_path = "/data/my.duckdb")
```

### ETL только новых статей

Режим `only_new = TRUE` перед загрузкой читает все `paper_id` из БД и фильтрует уже известные статьи на лету, страница за страницей. Останавливается как только накоплено `max_results` новых.

```r
# Скачать ровно 10 статей, которых нет в БД
etl(max_results = 10, only_new = TRUE)

# Скачать 50 новых (проверит не более 50*10 = 500 с arXiv)
etl(max_results = 50, only_new = TRUE)
```

Защита от зависания: потолок запросов к arXiv — `max_results * 10` (минимум 100). Если новых не хватает — функция завершается с сообщением.

### ETL с ML-классификацией

```r
# Стандартный ETL + автоматическая ML-классификация (если сервис доступен)
etl_with_ml(max_results = 100)

# Явно указать URL ML-сервиса
etl_with_ml(max_results = 100, ml_service_url = "http://localhost:5001")
```

### Ручное управление шагами

```r
# Шаг 1: загрузить сырые данные
papers <- get_arxiv_papers(max_results = 200)

# Шаг 2: сохранить в RDS
save_raw_data(papers)

# Шаг 3: загрузить из RDS
raw <- load_raw_data()

# Шаг 4: классифицировать
classified <- classify_data(raw)

# Шаг 5: сохранить в БД
result <- save_publications(classified)
cat("Добавлено:", result$inserted, "Обновлено:", result$updated)

# Шаг 6: прочитать из БД
pubs <- load_publications()
```

---

## Классификация статей

### Keyword-классификатор (`classify_data()`)

Основной классификатор работает без ML — на основе словарей ключевых слов. Для каждой аннотации подсчитывается взвешенный score по каждой категории: совпадение с ключевым словом даёт `nchar(keyword) * 0.1` очков. Побеждает категория с наибольшим score.

**Поддерживаемые теги (16 категорий):**

| Тег | Примеры ключевых слов |
|---|---|
| Threat Actor | attacker, adversary, apt, hacktivist, nation state |
| Cryptography | encryption, aes, rsa, tls, digital signature |
| Vulnerability | cve, zero day, buffer overflow, cvss, attack surface |
| Exploit | shellcode, rce, privilege escalation, rop chain |
| Attack Vector | phishing email, supply chain attack, brute force |
| Privacy Protection | differential privacy, gdpr, k-anonymity, data masking |
| Malware | ransomware, trojan, botnet, rootkit, dropper |
| Social Engineering | spear phishing, pretexting, bec, vishing |
| Network Attack | ddos, mitm, arp spoofing, dns poisoning |
| Log Event | siem, audit log, event correlation, syslog |
| Incident | data breach, incident response, forensic investigation |
| ML Methodology | neural network, gradient descent, backpropagation |
| Model Architecture | transformer, lstm, cnn, autoencoder, resnet |
| Learning Theory | pac learning, vc dimension, generalization bound |
| Evaluation & Benchmarking | f1 score, roc curve, confusion matrix, sota |
| ML/AI Security | adversarial attack, data poisoning, model stealing |
| other | (если ни одна категория не набрала очков) |

При равенстве score побеждает тег, первый по алфавиту (детерминированное поведение).

### ML-классификатор (`classify_with_ml()`)

Дополнительный классификатор на базе DistilBERT. Работает только при запущенном ML-сервисе. Результат пишется в отдельный столбец `ml_tag` / `ml_confidence`, не перезаписывая keyword-тег.

```r
# Проверить доступность сервиса
ml_service_is_healthy()  # TRUE / FALSE

# Классифицировать батч статей
raw <- load_raw_data()
ml_results <- classify_with_ml(raw, batch_size = 50)

# Записать ML-теги в БД
update_ml_tags(ml_results)
```

Если ML-сервис недоступен — `classify_with_ml()` возвращает `NA` в `ml_tag` без ошибки.

### Поиск и фильтрация

```r
pubs <- load_publications()

# Полнотекстовый поиск
results <- search_papers(pubs, query = "ransomware")

# Поиск + фильтр по году
results <- search_papers(pubs, query = "intrusion detection", year = 2024)

# Загрузка из БД с фильтрами (эффективнее — фильтрует на уровне SQL)
load_publications(year = 2024, category = "Cryptography", text = "lattice")
load_publications(limit = 100)
```

---

## ML-сервис

ML-сервис — самостоятельное Python-приложение (FastAPI), не зависящее от R. Общается с R-пакетом по HTTP.

### Архитектура модели

```
Вход: текст аннотации (до 256 токенов)
    ↓
DistilBERT-base-uncased (66M параметров, 768 скрытых)
    ↓ [CLS]-токен
Dropout(0.3) → Linear(768→384) → GELU → Dropout(0.15) → Linear(384→N)
    ↓
Softmax → предсказанный класс + confidence
```

### API-эндпоинты

**Inference:**

| Метод | Путь | Описание |
|---|---|---|
| GET | `/health` | Статус сервиса, число и имена загруженных моделей |
| GET | `/models` | Метаданные всех `.pt`-моделей в `MODELS_DIR` |
| GET | `/model_info?model=<name>` | Метаданные одной модели |
| POST | `/classify?model=<name>` | Пакетная классификация (список `{id, abstract}`) |
| POST | `/classify_single?model=<name>` | Классификация одной аннотации |
| POST | `/reload_models` | Сканирует `MODELS_DIR` заново, без перезапуска |

**Training pipeline** (см. раздел [Training Pipeline (GUI)](#training-pipeline-gui)):

| Метод | Путь | Описание |
|---|---|---|
| GET | `/training/health` | Диагностика: писабельность дисков, наличие SDK |
| GET / POST | `/training/config` | Таксономия классов + промпты + LLM creds |
| POST | `/training/collect` | Старт сбора arXiv в фоне |
| POST | `/training/label` | Старт LLM-разметки в фоне |
| POST | `/training/export_excel` | labeled.parquet → .xlsx |
| POST | `/training/train` | xlsx → CSV → `train_model.py` (subprocess) |
| GET | `/training/jobs[/{id}]` | Список / статус / лог job-ов |
| POST | `/training/jobs/{id}/cancel` | Отмена работы |
| GET | `/training/files/{raw\|labeled\|excel}` | Листинг артефактов |
| GET | `/training/files/{cat}/{filename}` | Скачать артефакт |
| GET / POST | `/training/tasks` | Список / регистрация ML-task overrides |
| DELETE | `/training/tasks/{name}` | Удалить override |

**Пример запроса к `/classify`:**

```bash
curl -X POST http://localhost:5001/classify \
  -H "Content-Type: application/json" \
  -d '{
    "papers": [
      {"id": "2401.00001", "abstract": "We study ransomware detection using deep learning..."}
    ]
  }'
```

**Пример ответа:**

```json
{
  "results": [
    {
      "id": "2401.00001",
      "tag": "malware",
      "confidence": 0.9234,
      "all_scores": {
        "malware": 0.9234,
        "network_security": 0.0312,
        "ml_security": 0.0201,
        ...
      }
    }
  ]
}
```

### Локальный запуск ML-сервиса

```bash
cd ml_service
pip install -r requirements.txt

# Без модели — сервис стартует, /classify вернёт 503
python -m uvicorn app:app --host 0.0.0.0 --port 5001

# С моделью
MODEL_PATH=/path/to/model.pt python -m uvicorn app:app --host 0.0.0.0 --port 5001
```

### Формат чекпойнта

ML-сервис ожидает `.pt`-файл в формате:

```python
{
    "cfg": {
        "model_name": "distilbert-base-uncased",
        "max_length": 256,
        "dropout": 0.3,
        ...
    },
    "label_encoder_classes": ["authentication", "blockchain_security", ...],
    "model_state": { ... }   # state_dict модели BertClassifier
}
```

---

## Training Pipeline (GUI)

GUI-пайплайн позволяет обучить собственный DistilBERT-классификатор без работы в терминале. Весь цикл — от сбора неразмеченных статей до получения готового `.pt` — управляется из вкладки **🎓 Обучение модели** в Shiny GUI. Под капотом работают эндпоинты `/training/*` и Python-пакет `ml_service/training_pipeline/`.

### Поток работы

```
1. Конфигурация ─── задать классы (snake_case) + system prompt + LLM creds
                    [сохраняется в training_data/config/training_config.json]
                                ↓
2. Сбор ─────────── arxiv search_query → N статей
                    [training_data/raw/arxiv_<ts>_<N>.parquet]
                                ↓
3. Разметка LLM ─── каждый абстракт → OpenAI / Anthropic / xAI Grok
                    [training_data/labeled/labeled_<ts>_<N>.parquet]
                                ↓
4. Excel ────────── parquet → .xlsx (для ручной правки меток)
                    [training_data/excel/<name>.xlsx]
                                ↓
5. Обучение ─────── xlsx → CSV → train_model.py (subprocess, MLflow)
                    [models/<model_name_out>.pt]
                                ↓
6. Reload models ── /reload_models → новая .pt доступна в /classify
                                ↓
7. Регистрация ──── POST /training/tasks → ml_tasks_override.yml
   (опционально)    задача появляется в дропдаунах ML и ETL
```

Все шаги — это асинхронные **jobs**: один JSON-файл на job в `training_data/jobs/`, переживает рестарт сервиса. Прогресс/лог опрашиваются Shiny раз в 2-3 секунды.

### Поддерживаемые LLM-провайдеры

| Провайдер | SDK | Дефолт base_url | Примеры моделей |
|---|---|---|---|
| OpenAI | `openai` | (sdk default) | `gpt-4o-mini`, `gpt-4o` |
| Anthropic | `anthropic` | (sdk default) | `claude-haiku-4-5-20251001`, `claude-sonnet-4-6` |
| xAI Grok | `openai` (compat) | `https://api.x.ai/v1` | `grok-3`, `grok-3-mini`, `grok-4` |

`base_url` можно оставить пустым — для Grok автоматически подставится `https://api.x.ai/v1`. Если случайно ввести полный путь типа `…/v1/responses` или `…/v1/chat/completions`, лишний хвост будет автоматически отрезан.

### Конфигурация

Хранится в `training_data/config/training_config.json`:

```json
{
  "classes": [
    {"name": "malware", "description": "Виды и анализ зловредного ПО"},
    {"name": "phishing", "description": "Социальная инженерия"},
    ...
  ],
  "system_prompt": "You are an expert cybersecurity research librarian...",
  "user_prompt_template": "Title: {title}\n\nAbstract: {abstract}\n\nPick exactly one category from:\n{classes_list}\n\nReply with just the category name.",
  "llm": {
    "provider": "grok",
    "model": "grok-3",
    "base_url": "",
    "api_key": "<masked in API responses>",
    "temperature": 0.0,
    "max_tokens": 32,
    "concurrency": 4,
    "request_timeout_secs": 60
  }
}
```

Доступные плейсхолдеры в `user_prompt_template`: `{title}`, `{abstract}`, `{classes_list}` (форматированный список с описаниями), `{classes}` (через запятую).

### Sizing рекомендации

| Сценарий | Размеченных строк | epochs | test+val | Качество |
|---|---|---|---|---|
| Sanity-check | 30-50 (≥6/класс) | 3 | 0.05+0.05 | Случайное |
| Прототип | 200-500 | 5-8 | 0.1+0.1 | Слабое |
| Боевая модель | 5000+ | 10-30 | 0.1+0.1 | Полезное |

`train_test_split` отбрасывает классы с числом примеров ниже `ceil(1/(test+val)) + 1`. Pre-flight check в пайплайне печатает `Dataset summary` перед обучением и падает с понятной ошибкой, если живых классов осталось < 2.

### Использование из R (без GUI)

Все функции `training_*` экспортируются и работают из R-консоли:

```r
library(cyberarxiv)

# 0. Настроить
training_set_config(
  llm = list(provider = "grok", model = "grok-3", api_key = "xai-..."),
  classes = list(
    list(name = "malware", description = "..."),
    list(name = "phishing", description = "...")
  )
)

# 1. Сбор
job_id <- training_start_collect(target = 1000L)
# Подождать
repeat {
  s <- training_get_job(job_id)
  cat(s$status, sprintf("%.0f%%", (s$progress %||% 0)*100), "\n")
  if (s$status %in% c("completed","failed","cancelled")) break
  Sys.sleep(5)
}
raw_file <- s$result$filename

# 2. Разметка
job_id <- training_start_label(raw_file, max_rows = 0L)  # 0 = все

# 3. Excel
job_id <- training_start_export_excel(labeled_path = "labeled_...parquet")

# 4. Обучение
job_id <- training_start_train(
  excel_path = "labeled_...xlsx",
  model_name_out = "my_model",
  epochs = 5L,
  mlflow_tracking_uri = "http://localhost:5000"
)

# 5. Hot-reload
training_reload_models()
```

См. [Справочник функций — Training](#training-pipeline) ниже для всех опций.

---

## Обучение модели (CLI)

CLI-режим нужен, если у вас уже есть готовый размеченный CSV/каталог чанков и не хочется проходить через GUI. Скрипт `ml_service/train_model.py` принимает два формата входных данных.

### Формат A — простой CSV (`--simple_csv`)

Один CSV с гибкими названиями колонок:

| Назначение | Допустимые имена (case-insensitive) |
|---|---|
| ID | `id`, `arxiv_id`, `paper_id` |
| Текст | `abstract`, `text`, `content`, `body` |
| Метка | `category`, `label`, `tag`, `class`, `primary_category` |

```bash
python3.10 train_model.py \
  --simple_csv /path/to/labeled.csv \
  --output_path ../models/my_model.pt
```

### Формат B — устаревший каталог (`--data_dir`)

Для обучения нужны два источника данных в директории `ml_service/data/`:

- `arxiv_classified_dedup.csv` — таблица с колонками `arxiv_id`, `primary_category`, `confidence`
- `arxiv_security_chunks/*.csv` — CSV-файлы с колонками `arxiv_id`, `title`, `abstract`

### Запуск обучения

```bash
cd ml_service

# Базовое обучение (80 эпох, early stopping через 15)
python train_model.py \
  --data_dir ./data \
  --output_path ../models/model.pt

# Полные параметры
python train_model.py \
  --data_dir ./data \
  --output_path ../models/model.pt \
  --model_name distilbert-base-uncased \
  --max_length 256 \
  --dropout 0.3 \
  --epochs 80 \
  --batch_size 32 \
  --lr 2e-5 \
  --warmup_ratio 0.1 \
  --weight_decay 0.01 \
  --patience 15 \
  --min_confidence 0.5 \
  --exclude_other \
  --seed 42
```

### Параметры обучения

| Параметр | Тип | По умолчанию | Описание |
|---|---|---|---|
| `--model_name` | str | `distilbert-base-uncased` | HuggingFace модель |
| `--max_length` | int | 256 | Максимальная длина токенов |
| `--dropout` | float | 0.3 | Dropout в классификационной голове |
| `--freeze_base` | flag | False | Заморозить веса BERT, обучать только голову |
| `--epochs` | int | 80 | Максимум эпох |
| `--batch_size` | int | 32 | Размер батча |
| `--lr` | float | 2e-5 | Learning rate (AdamW) |
| `--warmup_ratio` | float | 0.1 | Доля шагов для warmup |
| `--weight_decay` | float | 0.01 | L2-регуляризация |
| `--patience` | int | 15 | Early stopping: эпох без улучшения |
| `--min_confidence` | float | 0.0 | Минимальный confidence для включения в датасет |
| `--exclude_other` | flag | False | Исключить класс `other` из обучения |
| `--test_size` | float | 0.1 | Доля тестовой выборки |
| `--val_size` | float | 0.1 | Доля валидационной выборки |

Сохраняется только **лучший** чекпойнт (по `val_accuracy`). Результаты логируются в MLflow автоматически, если он установлен.

### Перезагрузка модели без перезапуска

После замены `model.pt` можно перезагрузить модель без остановки сервиса:

```bash
curl -X POST http://localhost:5001/reload_model
```

---

## Shiny GUI

Основной UI проекта — интерактивное веб-приложение на порту 3838.

```r
library(cyberarxiv)

# Запуск локально (откроет браузер)
launch_app()

# На другом порту
launch_app(port = 8080)

# Для Docker / сервера (без браузера)
launch_app(launch_browser = FALSE)

# С явным URL ML-сервиса
launch_app(ml_service_url = "http://ml-host:5001")
```

### Вкладки приложения

**📊 Обзор** — сводные метрики (всего статей, с ML-меткой, источников, статус ML-сервиса) + три графика (источники, теги, публикации по месяцам). Статус ML-сервиса автоматически перепроверяется каждые 30 секунд.

**📥 Загрузка (ETL)** — форма запуска ETL: галочки коллекторов (arXiv / CORE / КиберЛенинка / любые свои YAML-спеки), per-collector query overrides, выбор ML-task для пост-классификации. Показывает лог в реальном времени и таблицу последних загруженных.

**📚 Таблица статей** — полная таблица из БД с фильтрами по тексту, году, источнику, языку, keyword-тегу. Экспорт в CSV.

**🤖 ML-классификатор** — статус инференс-сервиса, список загруженных моделей, пакетная классификация (только новых / перезаписать все), ad-hoc классификация с выбором языка и задачи.

**📈 Аналитика** — топ-15 авторов, топ-25 слов, кросс-таблица keyword-тег × ML-тег.

**🎓 Обучение модели** ★ новое — 6 подвкладок: Конфигурация (классы + промпты + LLM creds через rhandsontable), Сбор данных, Разметка LLM, Excel, Обучение (с настраиваемым MLflow URI), Джобы (всё с auto-refresh).

**⚙ Настройки** — текущие пути и URL, кнопка переинициализации схемы БД.

---

## Схема базы данных

Используется DuckDB (встроенная колоночная БД, файл `cyberarxiv.duckdb`).

### Таблица `papers`

| Колонка | Тип | Описание |
|---|---|---|
| `paper_id` | VARCHAR | ID статьи на arXiv (без версии, напр. `2401.12345`) |
| `link` | VARCHAR | Полная ссылка на abs-страницу |
| `title` | VARCHAR | Заголовок статьи |
| `authors` | VARCHAR | Авторы через `, ` |
| `abstract` | VARCHAR | Аннотация |
| `categories` | VARCHAR | Категории arXiv, развёрнутые в полные названия через `, ` |
| `published_date` | TIMESTAMP | Дата первой публикации (UTC) |
| `updated_date` | TIMESTAMP | Дата последнего обновления (UTC) |
| `ingested_at` | TIMESTAMP | Время записи в БД (DEFAULT now()) |
| `tag` | VARCHAR | Keyword-тег (из `classify_data()`) |
| `ml_tag` | VARCHAR | ML-тег (из `classify_with_ml()`) |
| `ml_confidence` | DOUBLE | Уверенность ML-классификатора (0–1) |

Индексы: `paper_id`, `published_date`, `updated_date`, `tag`, `ml_tag`.

### Upsert-логика

При каждом вызове `save_publications()` выполняется транзакция:

1. Данные пишутся во временную таблицу `stg_papers`
2. `UPDATE papers SET ... FROM stg_papers WHERE paper_id = ... AND updated_date > p.updated_date` — обновляет существующие записи только если пришла более новая версия статьи
3. При UPDATE тег сохраняется: `COALESCE(NULLIF(trim(s.tag), ''), p.tag)` — пустой тег не затирает существующий
4. `INSERT INTO papers ... WHERE NOT EXISTS (SELECT 1 FROM papers WHERE paper_id = s.paper_id)` — добавляет только новые
5. `stg_papers` удаляется, транзакция коммитится (или откатывается при ошибке)

---

## Переменные окружения

| Переменная | По умолчанию | Описание |
|---|---|---|
| `CYBERARXIV_DB_PATH` | `data/cyberarxiv.duckdb` | Путь к файлу DuckDB |
| `ML_SERVICE_URL` | `http://localhost:5001` | URL ML-классификатора (для R-сервиса) |
| `ML_SERVICE_PORT` | `5001` | Порт ML-сервиса (для контейнера) |
| `MODEL_PATH` | `/srv/cyberarxiv-ml/models/model.pt` | Устаревший single-model путь |
| `MODELS_DIR` | `/srv/cyberarxiv-ml/models` | Директория со всеми `.pt`-моделями |
| `TRAINING_DATA_DIR` | каскадный fallback | База для training-pipeline артефактов (см. ниже) |
| `MLFLOW_TRACKING_URI` | `http://localhost:5000` | URL MLflow (читает train_model.py) |
| `MLFLOW_UI_URL` | `http://localhost:5000` | URL для ссылки в Shiny GUI |
| `MAX_RESULTS` | `1000` | Кол-во статей при ETL из Docker |
| `QUERY` | *(cybersecurity default)* | arXiv-запрос при ETL из Docker |
| `CYBERARXIV_COLLECTORS_DIR` | — | Доп. директория для YAML-коллекторов |

### TRAINING_DATA_DIR — каскадный fallback

Если `TRAINING_DATA_DIR` не задана, `paths.py` пробует кандидатов по очереди и выбирает первый, в который удалось писать:

1. `$TRAINING_DATA_DIR` (если задана)
2. `/srv/cyberarxiv-ml/training_data` — дефолт в Docker
3. `./training_data` — относительно CWD (при локальном запуске)
4. `~/.cyberarxiv/training_data` — последняя соломинка

Выбранный путь логируется один раз при старте сервиса. Это видно в `GET /training/health` в поле `training_data_dir`.

Путь к БД также можно задать через R-опцию:

```r
options(cyberarxiv.db_path = "/path/to/cyberarxiv.duckdb")
```

---

## Справочник функций

### ETL и загрузка данных

```r
# Основной пайплайн (fetch → RDS → DB → classify → update tags)
etl(max_results = 100, only_new = FALSE, db_path = NULL)

# То же + ML-классификация
etl_with_ml(max_results = 100, ml_service_url = NULL)

# Загрузить статьи с arXiv (без сохранения)
get_arxiv_papers(query = NULL, max_results = 100)

# Сохранить/загрузить сырые данные (RDS)
save_raw_data(data, filename = "arxiv_papers.rds", dir = "raw-data")
load_raw_data(filename = "arxiv_papers.rds", dir = "raw-data")

# Upsert в DuckDB
save_publications(data, db_path = NULL)

# Чтение из DuckDB с фильтрами
load_publications(db_path = NULL, year = NULL, category = NULL, text = NULL, limit = NULL)
```

### Классификация

```r
# Keyword-классификация (добавляет колонку tag)
classify_data(data)

# ML-классификация через HTTP
classify_with_ml(data, ml_service_url = NULL, batch_size = 50)

# Записать ML-теги в БД
update_ml_tags(ml_results, db_path = NULL)

# Проверить доступность ML-сервиса
ml_service_is_healthy(ml_service_url = NULL)
```

### Поиск и анализ текста

```r
# Поиск в загруженных данных
search_papers(data, query = NULL, year = NULL)

# Топ-N слов из аннотаций
get_top_words(data, n = 30)

# Топ-N слов по каждой теме
get_top_words_by_tag(data, n = 5)
```

### UI

```r
# Shiny GUI (7 вкладок, включая Обучение модели)
launch_app(host = "0.0.0.0", port = 3838, ml_service_url = NULL, launch_browser = interactive())
```

### Training pipeline

```r
# Конфигурация
training_get_config()
training_set_config(classes = NULL, system_prompt = NULL,
                    user_prompt_template = NULL, llm = NULL)

# Async-jobs (возвращают job_id)
training_start_collect(target, query = NULL, page_size = 200L)
training_start_label(raw_path, max_rows = 0L)
training_start_export_excel(labeled_path, max_rows = 0L)
training_start_train(excel_path, model_name_out = "custom_model",
                     base_model = "distilbert-base-uncased",
                     epochs = 8L, batch_size = 16L, lr = 2e-5,
                     max_length = 256L, test_size = 0.1, val_size = 0.1,
                     mlflow_tracking_uri = NULL)

# Управление job-ами
training_get_job(job_id)
training_list_jobs(type = NULL, limit = 50L)
training_cancel_job(job_id)

# Артефакты
training_list_files(category = c("raw","labeled","excel"))
training_download_file(category, filename, dest_path)

# Hot-reload новых моделей в инференс-сервис
training_reload_models()

# Зарегистрировать обученную модель как новую ML-task
register_ml_task(task_name = "my_grok_task",
                 label = "Моя модель (Grok)",
                 model_name = "my_grok_model",  # имя .pt без расширения
                 language = "en")
```

---

## Troubleshooting

### `Permission denied: '/srv/cyberarxiv-ml'`
Сервис запущен локально (вне Docker), и не может писать в `/srv/`. Решение: перезапустить с `TRAINING_DATA_DIR=$PWD/training_data`. С v0.2 каскадный fallback должен это решить автоматически.

### `404 No handler found on route` (xAI Grok)
В поле `base_url` ввели `https://api.x.ai/v1/responses` или `…/chat/completions`. Очистите поле — для Grok дефолт `https://api.x.ai/v1` подставится сам, и SDK добавит `/chat/completions`. Лишний хвост обрезается автоматически в `_normalize_base_url`.

### `Ошибка сохранения промптов` без подробностей
Нажмите 🔌 «Проверить подключение» во вкладке Конфигурация. Получите детальный JSON: `config_writable`, `sdks.openai`, `sdks.anthropic`, конкретные ошибки. Если `sdks.openai=FALSE` — `pip install openai>=1.40.0` (для контейнера это уже в `requirements.txt`, проверьте, что образ пересобран).

### `BadZipFile: File is not a zip file` при обучении
LibreOffice/Excel держит файл открытым → создаёт `.~lock.<name>.xlsx#` или `~$<name>.xlsx`. Закройте файл в редакторе. С v0.2 такие файлы фильтруются на стороне сервера в `/training/files/excel`.

### `n_samples=0, test_size=0.2` при обучении
Слишком мало размеченных строк или мало примеров на класс. Pre-flight check теперь печатает `Dataset summary` и точно говорит, сколько примеров на класс нужно. Понизьте `test_size`/`val_size` в Training-вкладке или соберите больше данных.

### `MLFLOW_TRACKING_URI=http://cyberarxiv-mlflow:5000` при локальном запуске
Этот адрес указывает на Docker-сервис, который не существует на хосте. В вкладке Обучение есть поле «MLflow tracking URI» — введите там `http://localhost:5000`. Либо `Sys.setenv(MLFLOW_TRACKING_URI = "http://localhost:5000")` в R-консоли (применяется к новым job-ам без рестарта Shiny).

### Не двигается прогресс обучения
Версии до v0.2 показывали 5% весь run. С v0.2 прогресс парсится из stdout `train_model.py`: эпохи занимают шкалу 5%-85%, `Final evaluation` → 92%, `Training complete` → 100%.

### Контейнер ML-сервиса не подхватывает изменения в коде
`docker-compose down && docker-compose up --build cyberarxiv-ml`. Без флага `--build` старый image остаётся.

---

## Авторы

- Zvonov (aleksandr.zwonov@yandex.ru)
- Kondrashkin (alexkondrol@yandex.ru)
- Dolgov (dolgov18012005@yandex.ru)
- Trembachev (trembochev@yandex.ru)
- Mozgov — maintainer (IT-life1@yandex.com)

## Лицензия

MIT — см. файл [LICENSE](LICENSE).
