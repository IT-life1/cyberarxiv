# CyberArXiv MCP Server

MCP-сервер (Model Context Protocol) для проекта CyberArXiv. Позволяет AI-ассистентам (Claude Desktop, Cursor и др.) работать с базой данных научных статей по кибербезопасности через естественный язык.

## Что это даёт

Без MCP-сервера поиск статей требует открытия Shiny-дашборда или написания R-кода. С MCP-сервером AI-ассистент может выполнять запросы напрямую:

```
"Найди статьи про ransomware за 2024 год на русском языке"
→ Claude вызывает search_papers(query="ransomware", year=2024, language="ru")
→ Возвращает список статей из DuckDB

"Классифицируй этот текст: [abstract]"
→ Claude вызывает classify_paper(abstract="...", language="en")
→ ML-модель возвращает тему и уверенность
```

## Инструменты (Tools)

| Tool | Описание | Параметры |
|------|----------|-----------|
| `search_papers` | Поиск статей | `query`, `category`, `year`, `source`, `language`, `limit` |
| `get_paper` | Получить статью по ID | `paper_id` |
| `get_stats` | Статистика базы | — |
| `get_categories` | Список категорий | — |
| `classify_paper` | ML-классификация текста | `abstract`, `language` |
| `run_ml_batch` | Пакетная ML-классификация | `only_new`, `limit` |
| `fetch_arxiv` | Скачать статьи с arXiv в БД | `query`, `max_results` |
| `fetch_cyberleninka` | ⚠️ experimental — статьи с КиберЛенинки (OAI-PMH), часто без аннотаций | `set_spec`, `max_results` |
| `fetch_core` | Скачать статьи с CORE API в БД (нужен `CORE_API_KEY`) | `query`, `max_results` |
| `fetch_by_url` | Скачать одну статью по URL/DOI в БД | `url` |

> **CyberLeninka — ограничение.** OAI-PMH-фид КиберЛенинки в большинстве записей
> не отдаёт `dc:description` (аннотацию). Поэтому после `fetch_cyberleninka` в БД
> попадают преимущественно метаданные без текста, и ML-классификатор по теме на
> таких записях работает плохо. Инструмент оставлен для случаев, когда нужны
> ссылки/авторы, а не тематическая классификация.

## Структура

```
mcp_server/
├── server.py        # MCP-сервер, определение tools
├── db.py            # Работа с DuckDB (чтение, запись ml_tag, upsert внешних статей)
├── fetchers.py      # Загрузка статей из arXiv, КиберЛенинка, CORE, по URL/DOI
├── ml_client.py     # HTTP-клиент к ML-сервису (:5001)
├── test_db.py       # Тесты db.py (7 тестов)
├── test_ml_client.py # Тесты ml_client.py (4 теста, mock)
├── test_server.py   # Тесты server.py (5 тестов)
├── requirements.txt # mcp[cli], duckdb, httpx
└── Dockerfile       # python:3.10-slim
```

## Запуск локально

```bash
cd mcp_server
pip install -r requirements.txt
python server.py
```

## Запуск тестов

```bash
cd mcp_server
python -m pytest test_db.py test_ml_client.py test_server.py -v
```

## Конфигурация

| Переменная | По умолчанию | Описание |
|-----------|-------------|---------|
| `CYBERARXIV_DB_PATH` | `data/cyberarxiv.duckdb` | Путь к DuckDB |
| `ML_SERVICE_URL` | `http://localhost:5001` | Адрес ML-сервиса |
| `ML_DEFAULT_MODEL` | `best_model` | Модель по умолчанию |
| `MCP_TRANSPORT` | `stdio` | Транспорт: `stdio` \| `streamable-http` \| `sse` |
| `MCP_HOST` | `127.0.0.1` (локально) / `0.0.0.0` (Docker) | Bind-хост для сетевых транспортов |
| `MCP_PORT` | `8000` (локально) / `5002` (Docker) | Порт для сетевых транспортов |
| `CORE_API_KEY` | — | Ключ CORE API (нужен только для `fetch_core`) |

## Транспорты

- **`stdio`** (по умолчанию) — клиент сам запускает процесс, общение через stdin/stdout. Используется Claude Desktop.
- **`streamable-http`** — новый стандарт MCP (2025). Один HTTP-эндпоинт `/mcp` на `MCP_HOST:MCP_PORT`. Поддерживается Claude.ai (Custom integrations), Cursor, mcp-inspector.
- **`sse`** — старый Server-Sent Events транспорт. Deprecated, но всё ещё работает в части клиентов.

В `docker-compose.yml` по умолчанию выставлен `streamable-http` на `0.0.0.0:5002`, эндпоинт — `http://localhost:5002/mcp`.

## Подключение в Claude Desktop (stdio)

Добавить в `~/.config/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "cyberarxiv": {
      "command": "python",
      "args": ["/path/to/cyberarxiv/mcp_server/server.py"],
      "env": {
        "CYBERARXIV_DB_PATH": "/path/to/data/cyberarxiv.duckdb",
        "ML_SERVICE_URL": "http://localhost:5001"
      }
    }
  }
}
```

## Подключение по HTTP (Claude.ai web, Cursor, mcp-inspector)

После `docker compose up -d cyberarxiv-mcp` сервер слушает на `http://localhost:5002/mcp`. Проверить:

```bash
docker compose logs cyberarxiv-mcp   # должно быть «Uvicorn running on http://0.0.0.0:5002»
npx @modelcontextprotocol/inspector  # затем ввести URL http://localhost:5002/mcp
```

В Claude.ai → Settings → Connectors → Add custom connector → указать URL `http://<host>:5002/mcp`.

> **Безопасность.** В дефолтной конфигурации порт открыт на `0.0.0.0` без аутентификации. На публичных хостах закройте его firewall-ом, или прокиньте только на `127.0.0.1` (`ports: ["127.0.0.1:5002:5002"]`), или поставьте reverse-proxy с basic-auth / OAuth.

## Запуск через Docker

```bash
docker compose up cyberarxiv-mcp
```

Сервис автоматически ожидает готовности ML-сервиса (`depends_on: cyberarxiv-ml`). Чтобы переключить транспорт обратно на stdio (например, для CLI-клиента, который сам spawn-ит процесс), задайте `MCP_TRANSPORT=stdio` и уберите `ports:` из `docker-compose.yml`.

## Поведение при ошибках

- **ML-сервис недоступен**: `classify_paper` и `run_ml_batch` возвращают сообщение об ошибке, остальные tools продолжают работать
- **DuckDB не найдена**: все tools возвращают пустой результат или ошибку с путём
- **Поиск без результатов**: возвращается пустой список, не ошибка

## Примеры диалогов с Claude Desktop

После подключения MCP-сервера к Claude Desktop, Claude может выполнять следующие запросы:

**Поиск по теме:**
```
Пользователь: Найди статьи про атаки на промышленные системы (ICS/SCADA)
Claude: [вызывает search_papers(query="ICS SCADA industrial control")]
→ Возвращает список найденных статей с авторами, датами и аннотациями
```

**Статистика:**
```
Пользователь: Сколько всего статей собрано и из каких источников?
Claude: [вызывает get_stats()]
→ "В базе 3 421 статья: arXiv — 2 890, КиберЛенинка — 531"
```

**Классификация нового текста:**
```
Пользователь: Определи тему по аннотации: "We propose a novel method..."
Claude: [вызывает classify_paper(abstract="...", language="en")]
→ "Тема: Network Security, уверенность: 0.87"
```

**Пакетная классификация:**
```
Пользователь: Запусти ML-классификацию для новых статей
Claude: [вызывает run_ml_batch(only_new=True, limit=200)]
→ "Классифицировано 47 статей"
```

**Загрузка извне:**
```
Пользователь: Скачай 20 свежих статей про supply-chain attacks с arxiv
Claude: [вызывает fetch_arxiv(query="cat:cs.CR AND all:supply chain", max_results=20)]
→ "arxiv: получено 20, добавлено 18, обновлено 2"

Пользователь: Добавь статью https://arxiv.org/abs/2401.12345 в базу
Claude: [вызывает fetch_by_url(url="https://arxiv.org/abs/2401.12345")]
→ "arxiv: получено 1, добавлено 1, обновлено 0"
```

Семантика fetch:
- Метаданные записываются в таблицу `papers` через атомарный upsert (staging-таблица).
- Уже существующая запись обновляется только если у внешней версии более свежий `updated_date`.
- Keyword-тег (`tag`) и ML-результаты не затираются при повторной загрузке.
- PDF не скачиваются — только метаданные (заголовок, авторы, аннотация, ссылка, категории, даты).

## Архитектура ML-интеграции

`ml_client.py` взаимодействует с FastAPI ML-сервисом через два эндпоинта:

- `POST /classify_single` — для одиночной классификации (`classify_paper`)
- `POST /classify` — для пакетной классификации (`run_ml_batch`)

Модель выбирается через `ML_DEFAULT_MODEL`. Если модель не загружена, сервис возвращает 503 — MCP-сервер перехватывает это и возвращает понятное сообщение об ошибке вместо исключения.
