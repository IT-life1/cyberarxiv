# Локальный запуск без Docker

Этот документ описывает, как поднять весь стек (ML-сервис + Shiny GUI + MLflow + training pipeline) на одной машине без Docker. Если можете использовать Docker — `docker-compose up --build` проще, см. README.

## Требования

- R ≥ 4.3
- Python ≥ 3.10 (3.10 или 3.11; **не пробуйте 3.12** — некоторые из transitive-зависимостей пока не собираются)
- pip
- ~3 GB на диске (PyTorch + DistilBERT)

> **Важно**: на этом проекте `python3` в pyenv может оказаться 3.12 без ML-зависимостей. В Linux надёжно использовать **`/usr/bin/python3.10`** напрямую — все команды ниже его и используют.

---

## 1. ML-сервис (Python/FastAPI)

### 1.1 Установка зависимостей

```bash
cd ml_service
python3.10 -m pip install --user -r requirements.txt
```

В `requirements.txt`:

```
fastapi, uvicorn, torch, pydantic, mlflow, transformers, scikit-learn,
numpy, pandas, tqdm, openai, anthropic, openpyxl, pyarrow, requests, python-multipart
```

Проверьте, что модули видны:

```bash
python3.10 -c "
mods = ['fastapi','torch','transformers','mlflow','openai','anthropic',
        'openpyxl','pyarrow','sklearn']
for m in mods:
    try: __import__(m); print('OK  ', m)
    except Exception as e: print('FAIL', m, '-', e)
"
```

### 1.2 Запуск сервиса

```bash
cd "$(pwd)"   # корень проекта
cd ml_service

TRAINING_DATA_DIR="$(cd .. && pwd)/training_data" \
MODELS_DIR="$(cd .. && pwd)/models" \
MLFLOW_TRACKING_URI=http://localhost:5000 \
python3.10 -m uvicorn app:app --host 0.0.0.0 --port 5001
```

Что делают env-vars:

| Переменная | Зачем |
|---|---|
| `TRAINING_DATA_DIR` | где training-pipeline складывает parquet/xlsx/jobs/config; **общая папка для R и Python** |
| `MODELS_DIR` | откуда инференс читает `.pt`-чекпойнты и куда падают новые после обучения |
| `MLFLOW_TRACKING_URI` | URL MLflow tracking сервера |

Если `TRAINING_DATA_DIR` не задать, сработает каскадный fallback (см. README → Переменные окружения), и сервис подберёт писабельную папку сам.

### 1.3 Health-check

```bash
curl http://localhost:5001/health
curl http://localhost:5001/models
curl http://localhost:5001/training/health | python3.10 -m json.tool
```

В `/training/health` важно:
- `ok: true`
- `config_writable: true`
- `sdks: {openai: true, anthropic: true}`
- `errors: []`

Если `config_writable: false` — папка `training_data` не пишется, поправьте `TRAINING_DATA_DIR`.
Если `sdks.openai: false` — `python3.10 -m pip install --user "openai>=1.40.0"`.

---

## 2. MLflow Tracking Server

Без него обучение работает (логирование в `try/except`), но run-ы не сохраняются.

```bash
cd "$(pwd)"   # корень проекта
mkdir -p mlflow/artifacts

mlflow server \
  --backend-store-uri "sqlite:///$(pwd)/mlflow/mlflow.db" \
  --default-artifact-root "file://$(pwd)/mlflow/artifacts" \
  --host 127.0.0.1 --port 5000
```

UI: http://localhost:5000.

После каждого `training_start_train()` появится новый run в эксперименте `cyberarxiv-classifier`.

---

## 3. R-пакет

### 3.1 Установка

```r
# Вариант 1 — через renv (рекомендуется)
install.packages("renv")
renv::restore()

# Вариант 2 — через pak (быстрее)
install.packages("pak")
pak::local_install(".", dependencies = TRUE)
```

Дополнительно для GUI:

```r
install.packages(c("shiny", "DT", "rhandsontable", "plotly"))
```

### 3.2 ETL-пайплайн

```r
library(cyberarxiv)

# Только keyword-классификация (ML не нужен)
etl(max_results = 100)

# С ML-классификацией
Sys.setenv(ML_SERVICE_URL = "http://localhost:5001")
etl_with_ml(max_results = 100)
```

### 3.3 Shiny GUI (с training pipeline)

```r
library(cyberarxiv)
Sys.setenv(ML_SERVICE_URL = "http://localhost:5001")
Sys.setenv(MLFLOW_TRACKING_URI = "http://localhost:5000")
Sys.setenv(MLFLOW_UI_URL = "http://localhost:5000")
launch_app(host = "127.0.0.1", port = 3838, launch_browser = FALSE)
```

Открыть: http://localhost:3838 → вкладка **🎓 Обучение модели**.

### 3.4 Quarto-дашборд

```r
library(cyberarxiv)
render_dashboard()
serve_dashboard()  # http://localhost:8000
```

---

## Порядок запуска

В трёх отдельных терминалах:

| # | Терминал | Что |
|---|---|---|
| 1 | `mlflow server …` | Tracking UI на :5000 |
| 2 | `python3.10 -m uvicorn app:app …` | Inference + training pipeline на :5001 |
| 3 | `R -e "launch_app(...)"` | Shiny GUI на :3838 |

Все три можно стартовать в фоне (`&`) или через tmux/screen. Перезапуск любого из них не требует трогать остальные — общение по HTTP, состояние на диске.

---

## Переменные окружения

| Переменная | По умолчанию | Кто читает |
|---|---|---|
| `ML_SERVICE_URL` | `http://localhost:5001` | R (Shiny + клиенты) |
| `MODELS_DIR` | каскадный fallback | Python (инференс + train_runner) |
| `TRAINING_DATA_DIR` | каскадный fallback | Python (training_pipeline.paths) |
| `MLFLOW_TRACKING_URI` | `http://localhost:5000` | Python (`train_model.py`) |
| `MLFLOW_EXPERIMENT_NAME` | `cyberarxiv-classifier` | Python (`train_model.py`) |
| `MLFLOW_UI_URL` | `http://localhost:5000` | R (для ссылки в Shiny) |
| `CYBERARXIV_DB_PATH` | `data/cyberarxiv.duckdb` | R |
| `CYBERARXIV_COLLECTORS_DIR` | — | R (доп. YAML-коллекторы) |

---

## Минимальный smoke-тест training pipeline

```r
library(cyberarxiv)
Sys.setenv(ML_SERVICE_URL = "http://localhost:5001")

# 1. Настроить классы и LLM
training_set_config(
  classes = list(
    list(name = "malware", description = "Malicious software"),
    list(name = "cryptography", description = "Encryption, hashing"),
    list(name = "other", description = "anything else")
  ),
  llm = list(provider = "grok", model = "grok-3", api_key = Sys.getenv("XAI_API_KEY"))
)

# 2. Сбор 100 статей
jid <- training_start_collect(target = 100L)
repeat {
  s <- training_get_job(jid); cat(s$status, "\n")
  if (s$status %in% c("completed","failed","cancelled")) break
  Sys.sleep(5)
}

# 3. Разметка
jid <- training_start_label(s$result$filename)
# … ждём аналогично

# 4. Excel
jid <- training_start_export_excel(labeled_path = "labeled_...parquet")

# 5. Обучение (для smoke-test test_size/val_size = 0.05 чтобы порог был 11, а не 6)
jid <- training_start_train(
  excel_path = "labeled_...xlsx",
  model_name_out = "smoke_test",
  epochs = 2L,
  test_size = 0.05, val_size = 0.05,
  mlflow_tracking_uri = "http://localhost:5000"
)

# 6. Hot-reload
training_reload_models()
```

После этого новая модель `smoke_test` будет доступна в `/classify?model=smoke_test`, а в MLflow появится run.

---

## Troubleshooting

См. одноимённый раздел в [README.md](./README.md#troubleshooting). Самые частые проблемы:

- **`Permission denied: '/srv/cyberarxiv-ml'`** — задайте `TRAINING_DATA_DIR` или используйте каскадный fallback.
- **`No module named 'openai'`** — `python3.10 -m pip install --user openai`.
- **`BadZipFile` при экспорте/обучении xlsx** — закройте файл в LibreOffice.
- **MLflow run-ы не появляются** — проверьте, что `MLFLOW_TRACKING_URI` указывает на запущенный сервер, а не на Docker-имя `cyberarxiv-mlflow`.
