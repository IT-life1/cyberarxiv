# `training_pipeline/`

Python-пакет, который превращает FastAPI-сервис из чистого инференса в полноценный «обучи свою модель» — с GUI, LLM-разметкой и MLflow-логированием. Подключается к `app.py` через эндпоинты `/training/*` и Background Tasks.

## Зачем

Базовый `cyberarxiv-ml` умеет **только** делать предсказания загруженной моделью. Чтобы обучить **свою**, исторически нужно было:

1. Вручную собрать датасет (CSV с колонками abstract+label).
2. Где-то разметить (вручную или LLM).
3. Запустить `train_model.py` через CLI с правильными путями.
4. Перезапустить контейнер, чтобы новая `.pt` подхватилась.

Этот пакет заворачивает всё в один пайплайн с асинхронными job-ами, доступный из Shiny GUI и из R-консоли через `training_*` функции.

## Из чего состоит

```
training_pipeline/
├── __init__.py            # public API (re-exports)
├── paths.py               # каскадный резолвер base-директории + sub-папки
├── config_store.py        # загрузка/сохранение training_config.json
├── job_store.py           # JSON-файлы джобов в training_data/jobs/
├── data_collector.py      # arXiv Atom → parquet (target_rows, query, retry)
├── llm_labeler.py         # OpenAI / Anthropic / xAI Grok разметка датасета
├── excel_export.py        # parquet → xlsx → CSV (для train_model.py)
├── train_runner.py        # subprocess-обёртка для train_model.py
├── pipeline.py            # оркестратор для FastAPI BackgroundTasks
└── README.md              # этот файл
```

### Поток данных

```
arXiv Atom API
    │ data_collector.collect_arxiv()
    ▼
training_data/raw/arxiv_<ts>_<N>.parquet
    │ llm_labeler.label_dataframe()  (OpenAI/Anthropic/Grok)
    ▼
training_data/labeled/labeled_<ts>_<N>.parquet
    │ excel_export.export_to_excel()
    ▼
training_data/excel/<name>.xlsx       ← человек правит метки руками
    │ excel_export.excel_to_training_csv()
    ▼
training_data/training_csv/<name>.csv
    │ train_runner.run_training()  →  subprocess(train_model.py)
    ▼
models/<model_name_out>.pt + MLflow run
    │ /reload_models
    ▼
loaded в инференс-сервис, доступна в /classify?model=<name>
```

Каждый шаг — отдельный job (`Job` объект из `job_store.py`), исполняется как FastAPI BackgroundTask. Состояние сохраняется в `training_data/jobs/<uuid>.json`, поэтому рестарт сервиса не теряет историю и пользователь может продолжить опрос статуса.

## Файловая структура артефактов (`TRAINING_DATA_DIR`)

```
training_data/
├── raw/                        # parquet после сбора (id,title,abstract,authors,published,link)
├── labeled/                    # parquet после LLM (+ label, llm_raw_answer)
├── excel/                      # xlsx для ручной правки
├── training_csv/               # CSV, скармливаемый train_model.py
├── jobs/<uuid>.json            # JSON со статусом, progress, log
└── config/training_config.json # классы, промпты, LLM creds
```

`paths.py` подбирает базу через каскад: `$TRAINING_DATA_DIR` → `/srv/cyberarxiv-ml/training_data` (Docker) → `./training_data` (CWD) → `~/.cyberarxiv/training_data` → `/tmp/...`. Первый писабельный кандидат выигрывает; путь логируется один раз при старте.

## API (мапится в `/training/*`)

Каждый эндпоинт в `app.py` — это тонкая обёртка вокруг функций отсюда:

| Эндпоинт | Функция здесь |
|---|---|
| `GET /training/config` | `config_store.load_config()` |
| `POST /training/config` | `config_store.save_config()` |
| `POST /training/collect` | `pipeline.run_collect_job()` |
| `POST /training/label` | `pipeline.run_label_job()` |
| `POST /training/export_excel` | `pipeline.run_export_excel_job()` |
| `POST /training/train` | `pipeline.run_train_job()` |
| `GET /training/jobs` | `job_store.list()` |
| `GET /training/jobs/{id}` | `job_store.get()` |
| `POST /training/jobs/{id}/cancel` | `job_store.update(status='cancelled')` |
| `GET /training/files/{cat}` | `os.listdir()` поверх `paths.<cat>_dir()` |
| `GET /training/files/{cat}/{name}` | `FileResponse` |
| `GET /training/health` | проверка writable + import openai |

## Поддерживаемые LLM-провайдеры

Все провайдеры используют единый OpenAI-совместимый SDK (`openai>=1.40`). Выбор провайдера определяет только `base_url` по умолчанию:

| `provider` | Дефолт `base_url` | Примеры моделей |
|---|---|---|
| `openai` | (SDK default) | `gpt-4o-mini`, `gpt-4o` |
| `grok` | `https://api.x.ai/v1` | `grok-3`, `grok-3-mini` |
| `deepseek` | `https://api.deepseek.com/v1` | `deepseek-chat`, `deepseek-reasoner` |
| `other` | (пользователь задаёт) | любая OpenAI-compatible модель |

### Environment variables

Переменные окружения имеют приоритет над конфигом в UI:

| Variable | Описание | Пример |
|---|---|---|
| `LLM_API_KEY` | API-ключ | `sk-...` |
| `LLM_MODEL` | Имя модели | `gpt-4o-mini` |
| `LLM_BASE_URL` | Base URL эндпоинта | `https://api.deepseek.com/v1` |
| `LLM_PROVIDER` | Провайдер (для логирования) | `deepseek` |

`_normalize_base_url()` обрезает случайно введённые суффиксы (`/chat/completions`, `/responses`, `/v1/responses`) — пользователь не должен думать об этом.

Разметка многопоточная (`ThreadPoolExecutor`), параметры берутся из `cfg["llm"]`:

- `concurrency` — число параллельных запросов
- `temperature` — для разметки лучше 0.0
- `max_tokens` — обычно достаточно 32 (LLM возвращает только название класса)
- `request_timeout_secs` — таймаут одного запроса
- 3 ретрая на запрос с exponential backoff

Ответ нормализуется (`_normalize`) — нижний регистр, снос пробелов/кавычек, замена дефисов на подчёркивание — и сравнивается с разрешённой таксономией. Если модель ответила что-то невнятное, метка падает на `"other"` (или первый класс, если `other` нет в таксономии).

## Прогресс обучения

`train_model.py` — внешний CLI-скрипт, его stdout пишется line-by-line в `train_runner.run_training()`. В `pipeline.run_train_job` обёртка `log_cb` ловит регексом `Epoch N/M` и обновляет `job.progress`:

| Стадия | progress |
|---|---|
| setup, CSV, pre-flight | 0.00 → 0.05 |
| training epochs | 0.05 → 0.85 (линейно по эпохам) |
| `Final evaluation` | 0.92 |
| `Training complete` / cancellation | 0.97 |
| done | 1.00 |

Поэтому в Shiny GUI прогресс-бар двигается в реальном времени без специальных IPC-каналов.

## Pre-flight check для обучения

Перед запуском subprocess пайплайн читает CSV и считает:

```
min_per_class = ceil(1 / (test_size + val_size)) + 1
```

Если в каком-то классе меньше → класс будет дропнут. Если живых классов остаётся <2 → пайплайн **не запускает** обучение, а падает с понятным сообщением в логе джоба:

```
Not enough labeled data to train. After applying the min_per_class=6
filter, only 0 class(es) survive — train_test_split needs at least 2.
Fix it by either: (a) labeling more rows so each class has >= 6 examples;
(b) lowering test_size and val_size in the Training params; or
(c) collapsing rare classes into 'other' before training.
```

Это спасает от непонятного `n_samples=0` traceback из sklearn 30 строк ниже.

## Расширение

- **Новый источник данных**: добавьте функцию в `data_collector.py` (например, `collect_pubmed`), напишите `pipeline.run_collect_<source>_job`, прокиньте новый эндпоинт в `app.py`. Job-ы и UI работают независимо от источника.
- **Новый LLM-провайдер**: добавьте класс в `llm_labeler.py` рядом с `_OpenAILike` / `_Anthropic` и обработайте его в `_build_client`.
- **Новая модель архитектуры**: train_runner запускает любой Python-скрипт как subprocess. Чтобы заменить DistilBERT на что-то другое, замените `train_model.py` или допишите альтернативу (например, `train_lora.py`) и подмените путь в `train_runner._train_script_path()`.

## Примечания

- Все пути относительные к base-папке резолвятся в `pipeline.run_*_job` по принципу: если `is_absolute()` — оставить как есть, иначе считать именем файла внутри соответствующей `<cat>_dir()`. Это позволяет UI передавать только имя файла из listing-эндпоинта, без полного пути.
- `_atomic_write` в `config_store` пишет `<file>.tmp` → `os.replace` для атомарного апдейта config-а.
- `train_runner._watch_cancel` опрашивает store раз в 5 секунд и `proc.terminate()` если пользователь нажал Cancel.
