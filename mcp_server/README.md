# CyberArXiv MCP Server

MCP-сервер ([Model Context Protocol](https://modelcontextprotocol.io)) для проекта CyberArXiv. Подключается к Claude.ai, Cursor, Claude Desktop, IDE-плагинам — и они получают 10 инструментов для поиска статей, ML-классификации и загрузки публикаций прямо из чата.

```text
"Найди свежие статьи про supply-chain attacks, скачай 20 штук
 и классифицируй их"
   ↓
Claude → fetch_arxiv(...) → search_papers(...) → run_ml_batch(...)
   ↓
"Готово, добавил 18 новых, 2 уже были. ML-теги:
 Malware — 11, Phishing — 4, Web Security — 3."
```

---

## Содержание

- [Запуск](#запуск)
- [Подключение клиентов](#подключение-клиентов)
- [Инструменты](#инструменты)
- [Примеры диалогов](#примеры-диалогов)
- [Транспорты](#транспорты)
- [Конфигурация](#конфигурация)
- [Безопасность](#безопасность)
- [Разработка](#разработка)
- [Архитектура ML-интеграции](#архитектура-ml-интеграции)

---

## Запуск

Самый простой путь — через основной `docker-compose.yml` репозитория, который запускает MCP на `http://localhost:5002/mcp` (streamable-http транспорт):

```bash
git clone https://github.com/IT-life1/cyberarxiv.git
cd cyberarxiv
docker compose up -d cyberarxiv-mcp cyberarxiv-ml
```

Проверка:

```bash
curl -sI http://localhost:5002/mcp | head -1
# HTTP/1.1 405 Method Not Allowed   (GET не поддерживается, это норма — клиент шлёт POST)
```

Для отладки без клиента есть [mcp-inspector](https://github.com/modelcontextprotocol/inspector):

```bash
npx @modelcontextprotocol/inspector
# в UI вставить URL http://localhost:5002/mcp
```

---

## Подключение клиентов

### Claude.ai (web)

Settings → Connectors → **Add custom connector** → URL `http://<host>:5002/mcp`.

Для публичных хостов закройте порт firewall'ом или поставьте reverse-proxy с auth — по умолчанию MCP открыт без авторизации (см. [Безопасность](#безопасность)).

### Cursor

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

Перезагрузить Cursor — сервер появится в списке доступных инструментов.

### Claude Desktop — через HTTP

В современных версиях Claude Desktop поддерживается streamable-http. `~/.config/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "cyberarxiv": {
      "url": "http://localhost:5002/mcp"
    }
  }
}
```

### Claude Desktop — через stdio

Альтернатива для случаев, когда Docker-контейнер MCP не нужен: клиент сам spawn'ит процесс. `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "cyberarxiv": {
      "command": "python",
      "args": ["/абс/путь/к/cyberarxiv/mcp_server/server.py"],
      "env": {
        "CYBERARXIV_DB_PATH": "/абс/путь/к/cyberarxiv/data/cyberarxiv.duckdb",
        "ML_SERVICE_URL": "http://localhost:5001",
        "MCP_TRANSPORT": "stdio"
      }
    }
  }
}
```

Или через `docker exec`, если контейнер уже запущен:

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

### Любой клиент через SDK

Если пишете свой клиент — используйте [официальный MCP SDK](https://github.com/modelcontextprotocol). Endpoint наш сервера: `POST http://localhost:5002/mcp` с MCP JSON-RPC payload'ом.

---

## Инструменты

| Tool | Что делает | Параметры |
|------|------------|-----------|
| `search_papers` | Поиск в DuckDB | `query`, `category`, `year`, `source`, `language`, `limit` |
| `get_paper` | Получить статью по ID | `paper_id` |
| `get_stats` | Сводная статистика базы | — |
| `get_categories` | Список тематических меток | — |
| `classify_paper` | ML-классификация одного текста | `abstract`, `language` |
| `run_ml_batch` | Пакетная ML-классификация (всё новое или всё) | `only_new`, `limit` |
| `fetch_arxiv` | Скачать статьи с arXiv в БД | `query`, `max_results` |
| `fetch_cyberleninka` | ⚠️ experimental — статьи с КиберЛенинки (OAI-PMH) | `set_spec`, `max_results` |
| `fetch_core` | Скачать статьи с CORE API в БД (нужен `CORE_API_KEY`) | `query`, `max_results` |
| `fetch_by_url` | Скачать одну статью по URL или DOI | `url` |

> **CyberLeninka — ограничение.** OAI-PMH-фид часто не отдаёт `dc:description` (аннотацию). После `fetch_cyberleninka` в БД попадают преимущественно метаданные без текста, ML-классификатор по теме на них работает плохо. Используйте, когда нужны ссылки/авторы, а не тематика. Подробности в [inst/collectors/README.md](../inst/collectors/README.md).

Полная спецификация инструментов (типы, дефолты, поведение при ошибках) — в [`mcp_server/server.py`](server.py).

---

## Примеры диалогов

### 1. Поиск + анализ темы

```text
🧑  Найди 5 свежих статей про ransomware на arXiv и расскажи, какие
    темы сейчас доминируют.

🤖  → search_papers(query="ransomware", source="arxiv", limit=5)
    ↩ 5 статей с published_date от 2025-09 до 2026-04

    Среди свежих работ преобладают три направления:
    1. Анализ ransomware-as-a-service (LockBit 4.0, Cl0p) — 2 статьи
    2. Детекция через сетевую телеметрию даже на зашифрованном трафике — 2
    3. Защита backup-инфраструктуры — 1
    ...
```

### 2. Скачивание + автоклассификация

```text
🧑  Добавь статью https://arxiv.org/abs/2401.12345 в базу и
    классифицируй её.

🤖  → fetch_by_url(url="https://arxiv.org/abs/2401.12345")
    ↩ {"inserted": 1, "updated": 0, "paper_id": "2401.12345"}

    → classify_paper(abstract="...текст из fetch...", language="en")
    ↩ {"tag": "Network Security", "confidence": 0.87}

    Готово: статья «...» добавлена. ML-классификатор отнёс её к
    «Network Security» (уверенность 0.87).
```

### 3. Batch-классификация нового пула

```text
🧑  Скачай 50 свежих статей про supply chain и прогони ML на всех
    новых.

🤖  → fetch_arxiv(query="cat:cs.CR AND all:supply chain", max_results=50)
    ↩ {"fetched": 50, "inserted": 47, "updated": 3}

    → run_ml_batch(only_new=true, limit=200)
    ↩ {"updated": 47, "unclassified_by_language": {}}

    Добавил 47 новых статей и классифицировал их. Распределение по
    темам: Malware — 18, Web Security — 11, Cryptography — 9,
    остальное — Networks/IoT/AI Security.
```

### 4. Перекрёстный анализ через стату

```text
🧑  Сколько у нас русскоязычных статей и какие самые частые темы?

🤖  → get_stats()
    ↩ {"total": 2843, "by_language": {"en": 2589, "ru": 254}, ...}

    → search_papers(language="ru", limit=100)
    ↩ 100 статей, доминируют темы (по tag):
    Malware — 38, Network Security — 22, Cryptography — 14

    В базе 254 русскоязычных статьи. Основные темы: Malware (~38%),
    Network Security (~22%), Cryptography (~14%). Поставщик —
    почти всё КиберЛенинка (источник cyberleninka).
```

---

## Транспорты

MCP-протокол определяет несколько транспортов; mcp[cli] поддерживает три.

| Транспорт | Когда нужен | По умолчанию |
|---|---|---|
| **`streamable-http`** | Любой клиент, поддерживающий HTTP MCP (Claude.ai, Cursor, современный Claude Desktop, mcp-inspector). Это новый стандарт MCP 2025. | ✅ в Docker |
| **`stdio`** | Локальный запуск рядом с Claude Desktop, где клиент сам spawn'ит процесс и общается через stdin/stdout. | ✅ при `python server.py` без env |
| **`sse`** | Старый Server-Sent Events. Deprecated в спецификации MCP, но всё ещё работает у некоторых клиентов. | — |

Переключение — через `MCP_TRANSPORT` env-вар. Из коробки `docker-compose.yml` выставляет `streamable-http` на `0.0.0.0:5002`; чтобы вернуть `stdio`, задайте `MCP_TRANSPORT=stdio` и уберите `ports:` из `cyberarxiv-mcp`.

---

## Конфигурация

| Переменная | Дефолт | Описание |
|-----------|--------|----------|
| `CYBERARXIV_DB_PATH` | `data/cyberarxiv.duckdb` | Путь к DuckDB. В Docker — `/data/cyberarxiv.duckdb` (bind-mount `./data`). |
| `ML_SERVICE_URL` | `http://localhost:5001` | Адрес `cyberarxiv-ml`. В Docker — `http://cyberarxiv-ml:5001`. |
| `ML_DEFAULT_MODEL` | `best_model` | Дефолтная модель для `classify_paper` и `run_ml_batch`. |
| `MCP_TRANSPORT` | `stdio` | `stdio` \| `streamable-http` \| `sse`. |
| `MCP_HOST` | `127.0.0.1` | Bind-хост для сетевых транспортов. В Docker — `0.0.0.0`. |
| `MCP_PORT` | `8000` | Порт сетевого транспорта. В Docker — `5002`. |
| `CORE_API_KEY` | — | Ключ [CORE API](https://core.ac.uk/services/api). Нужен только для `fetch_core`. Без него tool возвращает явную ошибку. |

---

## Безопасность

**Дефолтная конфигурация открывает MCP без авторизации.** Это удобно для локалки и доверенной сети, но опасно на публичных хостах: любой клиент, добравшийся до порта 5002, получает полный доступ к 10 инструментам — включая `fetch_*`, которые тянут внешние API под вашим IP, и `run_ml_batch`, который потребляет GPU/CPU.

Если поднимаете на сервере:

- **firewall:** закройте `5002` для всего, кроме доверенных IP.
- **bind на loopback:** в `docker-compose.yml` смените `ports: - "5002:5002"` на `ports: - "127.0.0.1:5002:5002"`. Тогда снаружи доступен только через SSH-tunnel.
- **reverse-proxy с auth:** nginx/Caddy с basic-auth или OAuth перед MCP-эндпоинтом.

Дополнительно: `CORE_API_KEY` лучше передавать через `.env` файл, а не в `docker-compose.yml`. Для LLM-ключей (если будут использоваться training pipeline) аналогично.

---

## Разработка

### Локальный запуск

```bash
cd mcp_server
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
CYBERARXIV_DB_PATH=../data/cyberarxiv.duckdb \
ML_SERVICE_URL=http://localhost:5001 \
MCP_TRANSPORT=streamable-http MCP_PORT=5002 \
python server.py
```

### Тесты

```bash
cd mcp_server
pip install pytest pytest-mock
python -m pytest test_db.py test_ml_client.py test_server.py -v
```

Покрытие сейчас: `db.py` — 7 тестов (DuckDB фикстура, поиск, upsert, статистика), `ml_client.py` — 4 теста (httpx-mock), `server.py` — 5 тестов.

### Добавить новый инструмент

1. Реализовать функцию в [`server.py`](server.py) или одном из модулей (`db.py`, `fetchers.py`, `ml_client.py`).
2. Зарегистрировать как MCP tool через декоратор:

   ```python
   @mcp.tool()
   def my_new_tool(arg1: str, arg2: int = 10) -> str:
       """Краткое описание для Claude."""
       result = some_logic(arg1, arg2)
       return json.dumps(result, ensure_ascii=False)
   ```

3. Покрыть тестом в `test_server.py`.
4. Обновить таблицу в этом README (раздел [Инструменты](#инструменты)).

### Структура

```
mcp_server/
├── server.py        # MCP-сервер, @mcp.tool()-декорированные функции
├── db.py            # DuckDB: поиск, upsert, json-extension load
├── fetchers.py      # arXiv, CyberLeninka (OAI), CORE, URL/DOI (Crossref)
├── ml_client.py     # HTTP-клиент к cyberarxiv-ml :5001
├── test_*.py        # pytest-тесты (16 штук)
├── requirements.txt # mcp[cli], duckdb, httpx
└── Dockerfile       # python:3.10-slim
```

---

## Архитектура ML-интеграции

`ml_client.py` общается с FastAPI-сервисом `cyberarxiv-ml` (см. [`ml_service/app.py`](../ml_service/app.py)) через два эндпоинта:

- `POST /classify_single` — для одиночной классификации (`classify_paper`).
- `POST /classify` — для пакетной (`run_ml_batch`).

`run_ml_batch` дополнительно агрегирует результаты по языку: если для языка `L` не загружена модель (см. mapping в [`inst/ml_tasks.yml`](../inst/ml_tasks.yml)), эти статьи попадают в `unclassified_by_language: {ru: 12, ...}` в JSON-ответе. Удобно для Shiny-баннера и для пользователя — Claude может сказать «12 русских статей пропущены, добавь ru-модель в задачу».

Модель выбирается через `ML_DEFAULT_MODEL`. Если модель не загружена в ML-сервисе (`/models` возвращает пустой словарь), 503 → MCP-сервер перехватывает и возвращает понятное сообщение об ошибке вместо исключения.

DuckDB-доступ — read-only для большинства инструментов; `fetch_*` и `run_ml_batch` открывают write-соединение для upsert / update. `json`-extension DuckDB подгружается из кода (`db.py:_ensure_extensions`) на каждом соединении — без этого `json_merge_patch` и `json_extract_string` падают в окружениях без сетевого autoload.
