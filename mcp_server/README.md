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

## Структура

```
mcp_server/
├── server.py        # MCP-сервер, определение tools
├── db.py            # Работа с DuckDB (чтение и запись ml_tag)
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

## Подключение в Claude Desktop

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

## Запуск через Docker

```bash
docker compose up cyberarxiv-mcp
```

Сервис автоматически ожидает готовности ML-сервиса (`depends_on: cyberarxiv-ml`).

## Поведение при ошибках

- **ML-сервис недоступен**: `classify_paper` и `run_ml_batch` возвращают сообщение об ошибке, остальные tools продолжают работать
- **DuckDB не найдена**: все tools возвращают пустой результат или ошибку с путём
- **Поиск без результатов**: возвращается пустой список, не ошибка
