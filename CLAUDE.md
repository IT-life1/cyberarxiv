# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

`cyberarxiv` is an R package that runs a full ETL pipeline: fetches cybersecurity papers from multiple configurable sources (arXiv, CORE REST API, КиберЛенинка OAI-PMH, and others via pluggable YAML collectors), stores them in DuckDB, classifies them by topic (keyword rules with language-aware routing + optional DistilBERT ML service with task-based model selection), and serves an interactive Shiny dashboard. Three Docker services work together: the R package service, a Python/FastAPI ML classifier, and an MLflow tracking server.

## Common commands

### R package development

```r
# Install package (skip deps if already installed)
pak::local_install(".", dependencies = FALSE, upgrade = FALSE)
# Full install with deps
pak::local_install(".", dependencies = TRUE)

# Regenerate documentation (roxygen2)
devtools::document()

# Run the ETL pipeline interactively
library(cyberarxiv)
etl(max_results = 100)                              # fetch + keyword-classify + save to DB
etl(max_results = 50, only_new = TRUE)              # only papers not yet in DB
etl(sources = c("arxiv", "cyberleninka"))           # specific collectors only
etl_with_ml(max_results = 100)                      # ETL + ML classification (default task)
etl_with_ml(task = "malware")                       # use malware detection task

# Load data from DB
load_publications(year = 2024, category = "Malware", text = "ransomware")
load_publications(source = "cyberleninka", language = "ru")

# List available collectors and ML tasks
list_collectors()
list_ml_tasks()      # shows tasks + which models are currently loaded
list_ml_models()     # raw model list from service

# Use custom keyword config for classification
classify_data(papers, keywords_file = "inst/keywords.yml")      # English
classify_data(papers, keywords_file = "inst/keywords_ru.yml")   # Russian
cfg <- load_keyword_config("inst/keywords.yml")
```

### ML service (standalone)

```bash
cd ml_service

# IMPORTANT: use /usr/bin/python3 (3.10 with correct deps), not pyenv python3 (3.12)
MODELS_DIR=../models /usr/bin/python3 -m uvicorn app:app --host 0.0.0.0 --port 5001

# Retrain English model
/usr/bin/python3 train_model.py --simple_csv my_data.csv --output_path ../models/best_model.pt

# For Russian model: edit train_model.py, change MODEL_NAME to "cointegrated/rubert-tiny2"
/usr/bin/python3 train_model.py --simple_csv ru_data.csv --output_path ../models/russian.pt

# API
curl http://localhost:5001/health
curl http://localhost:5001/models
curl -X POST http://localhost:5001/reload_models
curl -X POST "http://localhost:5001/classify?model=best_model" \
     -H "Content-Type: application/json" \
     -d '{"papers": [{"id": "1", "abstract": "text here"}]}'
```

### Docker (full stack)

```bash
mkdir -p data raw-data models mlflow
cp /path/to/model.pt models/best_model.pt
docker-compose up --build
UI_MODE=shiny docker-compose up
```

## Architecture

### ETL pipeline (the core flow)

```
Collectors (arXiv Atom, CORE REST API, КиберЛенинка OAI-PMH, …)
    ↓ collect_all()                # R/collector_registry.R
      - Applies id_prefix; SHA256-normalizes URL-based IDs
      - Auto-detects language from text (Cyrillic ratio > 25% → "ru")
RDS (raw-data/arxiv_papers.rds)
    ↓ save_raw_data()              # R/raw_data.R
DuckDB papers table (empty tag)
    ↓ save_publications()          # R/save_publications.R — upsert via staging table
.classify_by_lang()                # R/classify_data.R — routes by language:
      ru papers → inst/keywords_ru.yml
      en papers → built-in English keywords
    ↓ .update_tags()               # SQL UPDATE tag WHERE paper_id IN (...)
DuckDB papers table (with tag)
```

**Critical invariant**: papers saved to DB *before* classification. Classifier failure never loses data.

### Pluggable collectors (`R/collector_registry.R`, `inst/collectors/`)

Discovery order: `inst/collectors/` → `~/.cyberarxiv/collectors/` → `CYBERARXIV_COLLECTORS_DIR` env → `extra_dirs` arg.

**Supported types:**

| Type | Used by | Notes |
|------|---------|-------|
| `atom` | arxiv | Atom feed with pagination |
| `rss` | — | Standard RSS |
| `oai_pmh` | cyberleninka | OAI-PMH. **XPath must use `oai:` prefix** with registered namespace — default xmlns causes `<record>` to be invisible. Supports `oai_from` (date) and `max_pages` YAML fields. Falls back to header `datestamp` when `dc:date` absent. |
| `core_api` | core | CORE REST API v3. Free tier: max `limit=10`; `offset=0` must be **omitted** (HTTP 500). |
| `r_script` | custom | Runs an arbitrary R script |

**Built-in collectors:**
- `arxiv.yml` — arXiv Atom, cybersecurity query
- `core.yml` — CORE REST API v3, API key in YAML, `page_size: 10` (free tier cap)
- `cyberleninka.yml` — КиберЛенинка OAI-PMH, set `journal_32131` ("Вопросы кибербезопасности"), `language: ru`

**paper_id normalization** (in `.standardize_collector_output()`):
- URL-based IDs → `{prefix}{sha256(url)}` (compact, stable)
- Non-URL IDs (arXiv, CORE numeric) → `{prefix}{id}` (unchanged)

**Language detection**: auto from text, falls back to YAML `language:` field. Uses Cyrillic character ratio.

Standard output columns: `id, source, language, link, title, authors, abstract, categories, published_date, updated_date`.

### Two classifiers

**Keyword classifier** (`classify_data()` in `R/classify_data.R`):
- 16 categories, score = `sum(nchar(kw) * 0.1)` per whole-word match, alphabetical tie-break
- Falls back to `title` when `abstract` is empty (OAI-PMH sources often lack abstracts)
- Language-aware: `etl()` routes Russian papers to `inst/keywords_ru.yml` automatically
- External config via `keywords_file`, loaded with `load_keyword_config(path)`

**ML classifier** (`R/mlflow_client.R`):
- Task-based: user picks a task, language routing is automatic and hidden
- Task config: `inst/ml_tasks.yml` — maps task name → `{lang: model_name}`
- If a model for a language is not loaded → those papers silently skipped (ml_tag stays empty)
- Results in `ml_tag`/`ml_confidence` — never overwrites keyword `tag`
- `list_ml_tasks()` shows tasks with availability; `load_ml_tasks()` reads YAML only (no service call — safe at UI startup)

### ML task system (`inst/ml_tasks.yml`)

```yaml
default:
  label: "Общая классификация"
  models: {en: best_model, ru: russian}
malware:
  label: "Детализация малвари"
  models: {en: malware_en, ru: malware_ru}
```

Add tasks by appending to YAML — no code changes. Model not loaded = language silently skipped.

### Database (`R/db.R`)

DuckDB, single table `papers`. Path: `CYBERARXIV_DB_PATH` env → `cyberarxiv.db_path` option → `data/cyberarxiv.duckdb`.

Schema idempotent. Migrations add `ml_tag`, `ml_confidence`, `source`, `language` if missing.

Upsert: staging `stg_papers` → UPDATE (newer `updated_date`, COALESCE preserves tag) → INSERT new → DROP staging → COMMIT. Full transaction with ROLLBACK.

### ML service (`ml_service/`)

FastAPI + PyTorch DistilBERT (`distilbert-base-uncased` for English; use `cointegrated/rubert-tiny2` for Russian). Scans `MODELS_DIR/*.pt` at startup — filename (without `.pt`) = model name.

**Python environment**: system Python `/usr/bin/python3` is 3.10 with correct deps. pyenv `python3` is 3.12 and lacks ML dependencies. Always use `/usr/bin/python3`.

Checkpoint: `{"cfg": {...}, "label_encoder_classes": [...], "model_state": {...}}`.

Endpoints: `GET /health`, `GET /models`, `POST /classify?model=`, `POST /classify_single?model=`, `POST /reload_models`.

### Shiny app (`R/shiny_app.R`)

Launched via `launch_app()`. Tasks loaded statically from YAML at startup (`.build_ui(ml_task_choices)`) — no ML service call required to start the app.

**6 tabs:**
1. **Обзор** — metrics + 3 charts. ML status auto-refreshes every 30s + "Обновить" button.
2. **ETL** — collector checkboxes; compact query cards (atom/core_api → text query; oai_pmh → `from` date); ML task dropdown; live log.
3. **Таблица** — papers with source/language/tag/year filters + search.
4. **ML-классификатор** — task dropdown (not model); batch (only new / all); ad-hoc with language selector.
5. **Аналитика** — tag correlation heatmap and charts. Filters out empty `ml_tag`.
6. **Настройки** — DB path, reload.

Key input IDs: `etl_ml_task`, `ml_task_batch`, `ml_task_adhoc`, `ml_adhoc_lang`, `cq_{collector_name}`.

### `only_new = TRUE` in `etl()`

Reads all `paper_id` from DB, fetches up to `max(max_results * 5, 100)` per source, filters already-known IDs, caps to `max_results`. Works across all sources.

**CORE API note**: free tier returns ≤ 10 per request, Elasticsearch often returns fewer total than requested. CORE is a supplemental source, not primary. Use arXiv or КиберЛенинка for volume.

## Training pipeline (новое)

`ml_service/training_pipeline/` — end-to-end Python pipeline для обучения собственных DistilBERT-моделей через GUI. Подробный README — в `ml_service/training_pipeline/README.md`.

1. **Сбор сырых данных** с arXiv (`data_collector.py`) — 10k/20k/70k+ статей в parquet.
2. **Разметка LLM** (`llm_labeler.py`) — пользователь задаёт классы и системный промпт, LLM (OpenAI/Anthropic Claude/xAI Grok) проставляет метки. Все три провайдера за единым интерфейсом, выбор в GUI.
3. **Экспорт в Excel** (`excel_export.py`) — для ручной проверки/корректировки меток.
4. **Обучение** (`train_runner.py`) — конвертирует .xlsx → CSV → запускает существующий `train_model.py` как subprocess, логирует в MLflow, кладёт `.pt` в `MODELS_DIR`.
5. **Hot-reload** — после обучения GUI вызывает `/reload_models`, новая модель доступна сразу.

### FastAPI endpoints
- `GET /training/health` — диагностика (writable, sdks, paths, errors)
- `GET/POST /training/config` — таксономия классов, system prompt, LLM creds
- `POST /training/collect` — старт сбора arXiv (job-based)
- `POST /training/label` — старт LLM-разметки
- `POST /training/export_excel` — экспорт labeled parquet → xlsx
- `POST /training/train` — старт обучения (xlsx → csv → train_model.py → .pt)
- `GET /training/jobs[/{id}]` — статус и лог джобов
- `POST /training/jobs/{id}/cancel` — отмена джоба
- `GET /training/files/{raw|labeled|excel}[/{filename}]` — листинг и скачивание; lock-файлы (`.~lock.*`, `~$*`) отфильтрованы

### Storage и резолв путей

`paths.py` использует **каскадный fallback** для базовой папки: `$TRAINING_DATA_DIR` → `/srv/cyberarxiv-ml/training_data` → `./training_data` (CWD) → `~/.cyberarxiv/training_data` → `/tmp/cyberarxiv_training_data`. Первый писабельный кандидат выигрывает; путь логируется один раз. Это нужно потому, что разработчики часто запускают сервис локально (CWD = `ml_service/`), и `/srv/` без прав записи.

Структура:
- `raw/` — собранные сырые parquet
- `labeled/` — размеченные parquet
- `excel/` — выгрузки .xlsx
- `training_csv/` — производные CSV для `train_model.py`
- `jobs/` — JSON-файлы состояний джобов (переживают рестарт сервиса)
- `config/training_config.json` — таксономия + промпты + LLM-настройки

Папка маунтится в оба контейнера.

### LLM provider quirks
- **Grok**: использует OpenAI-compat SDK с `base_url=https://api.x.ai/v1`. `_normalize_base_url()` обрезает случайно введённые суффиксы (`/chat/completions`, `/responses`).
- **Anthropic**: `messages.create` API, `system` отдельно от user-message.
- API-ключ маскируется в `_redact()` перед возвратом из `/training/config`. Пустой `api_key` в payload **не** трёт сохранённый ключ — для очистки нужно явно передать `null` (на стороне Pydantic-модели).

### Pre-flight check для обучения

Перед запуском subprocess `pipeline.run_train_job` читает CSV и считает порог `min_per_class = ceil(1 / (test_size + val_size)) + 1`. Если живых классов <2 — джоб падает с понятной ошибкой и тремя вариантами решения, не доходя до sklearn-traceback `n_samples=0`. Параметры `test_size`/`val_size` настраиваются в Shiny UI на вкладке Обучение.

### Прогресс обучения

`train_model.py` — субпроцесс, поэтому ipc-канала нет. `pipeline.run_train_job` оборачивает `log_cb` регексом `Epoch (\d+)/(\d+)` и обновляет `job.progress` линейно от 0.05 до 0.85, потом 0.92 на `Final evaluation`, 0.97 на `Training complete`, 1.00 при успешном завершении. Прогресс-бар в Shiny двигается без специальных IPC-каналов.

### Diagnostic UX
- `R/training_client.R` имеет `*_safe` варианты, возвращающие `list(ok, data, error, status)` вместо exception. Shiny кнопки сохранения показывают точную ошибку из `error` поля.
- В UI вкладки Конфигурация есть кнопка **🔌 Проверить подключение**, дёргает `/training/health` и форматирует результат: writable, sdks, paths, ошибки.

### GUI: вкладка "Обучение модели"

Шесть подвкладок: **Конфигурация** (классы + промпты + LLM), **Сбор данных**, **Разметка LLM**, **Excel**, **Обучение**, **Джобы**. Использует `rhandsontable` для редактируемой таблицы классов. Списки файлов (raw/labeled/excel) перерисовываются через `reactivePoll` каждые 5 сек, прогресс — каждые 2 сек, таблица Джобы auto-refresh каждые 4 сек. Все dropdown сохраняют выбор пользователя при перерисовке (через `isolate(input$...)`).

В UI есть поле **MLflow tracking URI** (по умолчанию `http://localhost:5000`) — приоритетнее env-var, можно менять не перезапуская Shiny.

### Python deps (для контейнера ml_service)
`openai>=1.40.0`, `anthropic>=0.40.0`, `openpyxl`, `pyarrow`, `requests`, `python-multipart` — в `ml_service/requirements.txt`.

### R deps (для GUI)
`rhandsontable` — добавлен в `Suggests` в DESCRIPTION и устанавливается в Dockerfile R-сервиса.

### Known gotchas (повторяющиеся проблемы из практики)
- **`Permission denied: '/srv/cyberarxiv-ml'`** при локальном запуске → каскадный fallback в `paths.py` должен это разруливать; если нет — задать `TRAINING_DATA_DIR=$PWD/training_data`.
- **`No module named 'openai'`** — пользователь установил часть зависимостей. Лечится `pip install -r ml_service/requirements.txt` под правильным интерпретатором (на Linux это обычно `/usr/bin/python3.10`, не pyenv).
- **`BadZipFile: File is not a zip file`** — пользователь открыл .xlsx в LibreOffice → создался lock-файл `.~lock.<name>.xlsx#`. Сервер их фильтрует, но если `excel_to_training_csv` всё-таки нарвался — даём явное "close the file in LibreOffice" сообщение.
- **`MLFLOW_TRACKING_URI=http://cyberarxiv-mlflow:5000`** при локальном запуске — это Docker-имя, наружу не доступно. Поле в UI или `Sys.setenv(MLFLOW_TRACKING_URI = "http://localhost:5000")` в R-консоли.
- **`xAI 404 No handler found on route`** — пользователь ввёл полный URL в `base_url` (`/v1/responses` или `/v1/chat/completions`); SDK дописывает endpoint сам и получается 404. Лечится `_normalize_base_url`.

## No test suite

`testthat` is in `Suggests` but no `tests/` directory exists. There are no automated tests to run.
