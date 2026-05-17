# cyberarxiv

R-пакет для автоматического сбора, классификации и визуализации научных статей по кибербезопасности с [arXiv](https://arxiv.org), [CORE](https://core.ac.uk) и [КиберЛенинки](https://cyberleninka.ru). ETL → DuckDB → keyword-классификация → ML (DistilBERT) → Shiny GUI.

## ⚡ Быстрый старт

```bash
git clone https://github.com/IT-life1/cyberarxiv.git
cd cyberarxiv
docker compose up -d
```

Откройте **http://localhost:3838** — Shiny GUI с поиском, аналитикой, ML-классификатором и обучением моделей.

| Сервис | URL |
|---|---|
| 📊 Shiny GUI | http://localhost:3838 |
| 🤖 ML API | http://localhost:5001 |
| 📈 MLflow | http://localhost:5000 |
| 🔌 MCP (для Claude.ai / Cursor) | http://localhost:5002/mcp |

**Опционально**, чтобы заработала ML-классификация: скачайте [готовые веса](https://disk.yandex.ru/d/Vr8vB1gI23XflA) (~1.6 ГБ), положите оба файла в `./models/` и сделайте `curl -X POST http://localhost:5001/reload_models`.

Образы поставляются готовыми из [GitHub Container Registry](https://github.com/IT-life1/cyberarxiv/pkgs/container/cyberarxiv) — `docker compose` тянет их сам, локально собирать ничего не нужно.

➡️ [Подробности и опции](#быстрый-старт-docker) · [Локальная установка](#локальная-установка) · [Архитектура](#архитектура)

---

## 🔌 Подключение MCP

`cyberarxiv-mcp` поднимается на `http://localhost:5002/mcp` (streamable-http) и даёт AI-ассистенту 10 инструментов: `search_papers`, `get_paper`, `get_stats`, `get_categories`, `classify_paper`, `run_ml_batch`, `fetch_arxiv`, `fetch_cyberleninka`, `fetch_core`, `fetch_by_url`.

<details>
<summary><b>Claude.ai (web)</b> — Custom integration</summary>

Settings → Connectors → *Add custom connector* → URL `http://<host>:5002/mcp`. Если хост публичный — закройте порт firewall'ом или поднимите reverse-proxy с auth (по умолчанию MCP открыт без авторизации).

</details>

<details>
<summary><b>Cursor</b></summary>

`.cursor/mcp.json` в корне проекта:

```json
{
  "mcpServers": {
    "cyberarxiv": {
      "url": "http://localhost:5002/mcp"
    }
  }
}
```

</details>

<details>
<summary><b>Claude Desktop</b> — stdio (без Docker-инстанса MCP)</summary>

`~/.config/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "cyberarxiv": {
      "command": "docker",
      "args": ["exec", "-i", "cyberarxiv-mcp", "python", "server.py"],
      "env": {"MCP_TRANSPORT": "stdio"}
    }
  }
}
```

Альтернативно — поднять stdio локально без Docker: см. [mcp_server/README.md](mcp_server/README.md).

</details>

<details>
<summary><b>mcp-inspector</b> — для отладки</summary>

```bash
npx @modelcontextprotocol/inspector
# в UI указать URL: http://localhost:5002/mcp
```

</details>

Примеры диалога:

```
"Найди статьи про ransomware за 2024 год"
   → search_papers(query="ransomware", year=2024)

"Скачай 20 свежих публикаций с arxiv про supply-chain attacks"
   → fetch_arxiv(query="cat:cs.CR AND all:supply chain", max_results=20)

"Добавь https://arxiv.org/abs/2401.12345 в базу"
   → fetch_by_url(url="https://arxiv.org/abs/2401.12345")
```

Подробности и полный список параметров инструментов: [mcp_server/README.md](mcp_server/README.md).

---

## Содержание

- [Архитектура](#архитектура)
- [Структура проекта](#структура-проекта)
- [Быстрый старт (Docker) — детально](#быстрый-старт-docker)
- [Локальная установка](#локальная-установка)
- [Что внутри](#что-внутри) — сбор, классификация, ETL, GUI, обучение
- [Конфигурация (env vars)](#-конфигурация)
- [Документация](#-документация)
- [Troubleshooting](#troubleshooting)

---

## Архитектура

Четыре Docker-сервиса:

```
                   arXiv · CORE · КиберЛенинка · LLM API
                                    │
              ┌─────────────────────┼─────────────────────┐
              ▼                     ▼                     ▼
       ┌─────────────┐      ┌───────────────┐      ┌──────────────┐
       │ cyberarxiv  │ ───▶ │ cyberarxiv-ml │ ───▶ │  cyberarxiv- │
       │   :3838     │ HTTP │     :5001     │ HTTP │  mlflow:5000 │
       │ R + Shiny   │      │ FastAPI       │      │ MLflow       │
       └─────────────┘      │ PyTorch       │      │ Tracking     │
              ▲             │ DistilBERT    │      └──────────────┘
              │ DuckDB      └───────────────┘
              ▼                     ▲
       ┌─────────────┐               │
       │ cyberarxiv- │ ──────────────┘
       │   mcp:5002  │   AI-ассистенты (Claude.ai, Cursor, …)
       │ MCP server  │
       └─────────────┘
```

- **cyberarxiv** — собирает статьи (`collect_all`), keyword-классифицирует (`classify_data`), пишет в DuckDB; Shiny GUI на :3838.
- **cyberarxiv-ml** — DistilBERT-инференс (`/classify`, `/classify_single`) + GUI-training pipeline (`/training/*`).
- **cyberarxiv-mlflow** — MLflow Tracking server для метрик и `.pt`-артефактов.
- **cyberarxiv-mcp** — MCP-сервер, открывает поиск и fetch'еры внешним AI-клиентам.

Docker Compose поднимает их в порядке: `cyberarxiv-mlflow` → `cyberarxiv-ml` (ждёт healthy) → `cyberarxiv` + `cyberarxiv-mcp` параллельно.

---

## Структура проекта

```
R/              # R-пакет: коллекторы, ETL, классификация, Shiny GUI
ml_service/     # Python: FastAPI + PyTorch (инференс + training pipeline)
mcp_server/     # Python: MCP-сервер для AI-ассистентов
inst/           # YAML-спеки коллекторов, keyword-таксономии, ml_tasks.yml
docker/         # start.sh, run_etl.R, run_shiny.R
data/  raw-data/  models/  mlflow/  training_data/   # bind-mount данные (gitignored)
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

Чтобы `cyberarxiv-ml` мог классифицировать статьи, в `./models/` должны лежать `.pt`-файлы. Имена файлов значимы — они задают mapping `задача → язык → модель` в [`inst/ml_tasks.yml`](inst/ml_tasks.yml):

| Задача | Язык | Ожидаемый файл |
|---|---|---|
| `default` (общая классификация) | en | `models/best_model.pt` |
| `malware` (детализация малвари) | en | `models/best_model_malware_fin.pt` |

**Готовые веса** (только английские) можно скачать с Яндекс.Диска: https://disk.yandex.ru/d/Vr8vB1gI23XflA — положить оба файла в `./models/` до или после `docker compose up`.

Русские модели в готовом виде не поставляются. Если в `inst/ml_tasks.yml` для языка `ru` указана модель, которой нет в `./models/`, русскоязычные статьи пропускаются при batch-классификации, и в Shiny GUI над кнопкой запуска появляется баннер `no model for ru`. Обучить ru-модель можно через Shiny GUI (вкладка **🎓 Обучение модели**) — результирующий `.pt` сложится в ту же `./models/`.

Папка `./models/` смонтирована в контейнер `cyberarxiv-ml` через bind-mount, так что пересборка образа не нужна. После добавления файлов — либо `docker compose restart cyberarxiv-ml`, либо hot-reload без рестарта:

```bash
curl -X POST http://localhost:5001/reload_models
```

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

## Что внутри

### 🛰 Сбор статей
Коллекторы описываются YAML-файлами в [`inst/collectors/`](inst/collectors/), без R-кода. Поддерживаются типы `atom`, `rss`, `oai_pmh`, `json_api`, `r_script`. Из коробки идут [arXiv](inst/collectors/arxiv.yml), [CORE](inst/collectors/core.yml), [КиберЛенинка (OAI-PMH)](inst/collectors/cyberleninka.yml). Подробности и шаблон нового коллектора — в [inst/collectors/README.md](inst/collectors/README.md).

```r
collect_all(max_results = 500)               # все включённые источники
collect_all(sources = c("arxiv"),            # только arxiv
            max_results = 100)
list_collectors()                            # что доступно
```

### 🧠 Классификация

| Подход | Точка вызова | Сохраняется в |
|---|---|---|
| Keyword (`inst/keywords*.yml`) | `classify_data(df)` | `papers.tag` |
| ML (DistilBERT, per-language) | `classify_with_ml(df)` → `update_ml_tags(res, task_id="default")` | `papers.ml_results.<task>` |

Языковое разделение автоматическое: статьи делятся по колонке `language` и отправляются в модель, заданную в [`inst/ml_tasks.yml`](inst/ml_tasks.yml) для конкретной пары *task × язык*. Если модели для языка нет — статьи пропускаются, в Shiny над кнопкой батч-классификации появляется warning-баннер.

### 🏗 Полный ETL

`etl()` объединяет fetch → DuckDB upsert → keyword-классификация; `etl_with_ml()` добавляет ML-шаг.

```r
etl(max_results = 500, sources = c("arxiv", "core"))
etl_with_ml(max_results = 500, task = "default")
```

### 🎓 Обучение моделей (Shiny GUI)

Вкладка **Обучение модели** в Shiny GUI ведёт через 4 шага без R/Python-кода:

1. **Сбор данных** — выбираете задачу arXiv, тащите N тысяч статей в `training_data/raw/*.parquet`.
2. **LLM-разметка** — статьи прогоняются через OpenAI / Anthropic / xAI (ключ и промпт в Конфигурации) → `training_data/labeled/*.parquet`.
3. **Excel-экспорт** — labeled.parquet → `.xlsx` для ручной правки.
4. **Train** — fine-tune DistilBERT поверх размеченных данных, MLflow трекает run, готовый `.pt` падает в `./models/`. После — `register_ml_task()` подключает её как новую ML-task.

Архитектура training pipeline и подробности конфигурации — в [`ml_service/training_pipeline/`](ml_service/training_pipeline/) и [setup_local.md](setup_local.md).

### 📺 Shiny GUI

7 вкладок: 🎯 ETL · 🔍 Поиск · 📊 Таблица · 🤖 ML Classifier · 📈 Analytics · 🎓 Обучение модели · ⚙️ Настройки. Запуск из R:

```r
launch_app(host = "127.0.0.1", port = 3838)
```

### 🤖 ML API

REST-эндпоинты сервиса `cyberarxiv-ml` (порт 5001): `GET /health`, `GET /models`, `POST /classify`, `POST /classify_single`, `POST /reload_models`, плюс `/training/*` для GUI-pipeline. Полная спецификация — в [`ml_service/app.py`](ml_service/app.py); пример запроса:

```bash
curl -s -X POST http://localhost:5001/classify_single \
  -H 'Content-Type: application/json' \
  -d '{"id":"demo","abstract":"We detect ransomware..."}'
```

### 🗄 База данных

Одна таблица `papers` в DuckDB. Полная схема, индексы, upsert-логика и каскадный fallback для пути БД — в отдельном файле [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md).

```r
load_publications(language = "ru", category = "Malware", limit = 50)
search_papers(df, query = "ransomware", year = 2024)
```

---

## ⚙️ Конфигурация

| Переменная | Дефолт | Описание |
|---|---|---|
| `CYBERARXIV_DB_PATH` | каскадный fallback | Путь к DuckDB-файлу |
| `ML_SERVICE_URL` | `http://localhost:5001` | URL ML-сервиса |
| `ML_DEFAULT_MODEL` | `best_model` | Модель по умолчанию для MCP |
| `TRAINING_DATA_DIR` | каскадный fallback | База для training-pipeline артефактов |
| `MLFLOW_TRACKING_URI` | `http://localhost:5000` | MLflow tracking |
| `MAX_RESULTS` | `1000` | Кол-во статей при ETL из Docker |
| `QUERY` | *(default cybersecurity)* | arXiv-запрос при ETL из Docker |
| `CORE_API_KEY` | — | Ключ [CORE API](https://core.ac.uk/services/api) |
| `LLM_PROVIDER` / `LLM_API_KEY` / `LLM_MODEL` / `LLM_BASE_URL` | — | Override LLM-настроек UI (см. setup_local.md) |
| `MCP_TRANSPORT` / `MCP_HOST` / `MCP_PORT` | `stdio` / `127.0.0.1` / `8000` | Транспорт MCP-сервера (в Docker — `streamable-http` / `0.0.0.0` / `5002`) |

Каскадный fallback для путей: `env var` → R-option / Python-env → системный путь пакета → `./<name>/` относительно CWD.

---

## 📚 Документация

| Тема | Где |
|---|---|
| Подключение MCP, список инструментов | [mcp_server/README.md](mcp_server/README.md) |
| YAML-коллекторы, env-секреты, troubleshooting | [inst/collectors/README.md](inst/collectors/README.md) |
| Схема DuckDB, upsert-логика, миграции | [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md) |
| Локальная установка без Docker | [setup_local.md](setup_local.md) |
| API-функции R-пакета | `?function_name` в R или каталог [man/](man/) |
| Training pipeline (Python) | [ml_service/training_pipeline/](ml_service/training_pipeline/) |
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
