# Database Schema — CyberArXiv

CyberArXiv использует **DuckDB** как встроенное аналитическое хранилище.

## Таблица `papers`

Единственная таблица для хранения всех статей из всех источников.

```sql
CREATE TABLE IF NOT EXISTS papers (
  paper_id        VARCHAR,       -- уникальный идентификатор статьи
  link            VARCHAR,       -- URL оригинала
  title           VARCHAR,       -- заголовок
  authors         VARCHAR,       -- авторы через "; "
  abstract        VARCHAR,       -- аннотация
  categories      VARCHAR,       -- категории через "; "
  published_date  TIMESTAMP,     -- дата публикации
  updated_date    TIMESTAMP,     -- дата обновления
  ingested_at     TIMESTAMP DEFAULT now(),  -- дата загрузки в БД
  tag             VARCHAR,       -- keyword-тег (classify_data)
  ml_tag          VARCHAR,       -- legacy ML-тег (не использовать)
  ml_confidence   DOUBLE,        -- legacy confidence (не использовать)
  source          VARCHAR,       -- имя коллектора (arxiv / core / cyberleninka)
  language        VARCHAR        -- язык статьи (en / ru)
  -- + динамические колонки ml_tag_<task> и ml_confidence_<task>
);
```

## Per-task ML колонки

Каждая ML-задача хранит результаты в отдельных колонках:

```sql
-- Создаётся автоматически при первом запуске задачи
ALTER TABLE papers ADD COLUMN ml_tag_default      VARCHAR;
ALTER TABLE papers ADD COLUMN ml_confidence_default DOUBLE;

ALTER TABLE papers ADD COLUMN ml_tag_malware      VARCHAR;
ALTER TABLE papers ADD COLUMN ml_confidence_malware DOUBLE;
```

Функция `ensure_ml_task_columns(con, task_id)` в `R/db.R` создаёт колонки идемпотентно.

## Upsert-логика

Вставка через staging-таблицу — транзакционная, атомарная:

```sql
-- 1. Создать staging
CREATE TABLE stg_papers AS SELECT * FROM papers WHERE 1=0;

-- 2. Загрузить новые данные
INSERT INTO stg_papers VALUES (...);

-- 3. Обновить существующие (если updated_date новее)
UPDATE papers AS p
SET title = s.title, abstract = s.abstract, updated_date = s.updated_date,
    tag = COALESCE(p.tag, s.tag)          -- COALESCE: сохраняет существующий тег
FROM stg_papers AS s
WHERE p.paper_id = s.paper_id
  AND s.updated_date > p.updated_date;

-- 4. Вставить новые
INSERT INTO papers
SELECT s.* FROM stg_papers s
LEFT JOIN papers p ON s.paper_id = p.paper_id
WHERE p.paper_id IS NULL;

-- 5. Очистить
DROP TABLE stg_papers;
COMMIT;
```

**Критичный инвариант**: `COALESCE(p.tag, s.tag)` — keyword-тег никогда не затирается при re-upsert.

## Миграции

Миграции идемпотентны — безопасно запускать повторно:

```r
# R/db.R — .cyberarxiv_init_schema()
if (!"ml_tag" %in% existing_cols)
  DBI::dbExecute(con, "ALTER TABLE papers ADD COLUMN ml_tag VARCHAR;")
if (!"source" %in% existing_cols)
  DBI::dbExecute(con, "ALTER TABLE papers ADD COLUMN source VARCHAR;")
```

## Индексы

```sql
CREATE INDEX IF NOT EXISTS idx_papers_paper_id    ON papers(paper_id);
CREATE INDEX IF NOT EXISTS idx_papers_published   ON papers(published_date);
CREATE INDEX IF NOT EXISTS idx_papers_tag         ON papers(tag);
CREATE INDEX IF NOT EXISTS idx_papers_ml_tag      ON papers(ml_tag);
CREATE INDEX IF NOT EXISTS idx_papers_source      ON papers(source);
CREATE INDEX IF NOT EXISTS idx_papers_language    ON papers(language);
```

## Конфигурация пути к БД

Порядок разрешения пути (каскадный fallback):

1. Переменная окружения `CYBERARXIV_DB_PATH`
2. R-опция `cyberarxiv.db_path`
3. `system.file("extdata/cyberarxiv.duckdb", package = "cyberarxiv")`
4. `data/cyberarxiv.duckdb` (относительно рабочей директории)

## Подключение

```r
# Стандартное подключение (инициализирует схему)
con <- .cyberarxiv_connect()

# Read-only (для load_publications)
con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_path, read_only = TRUE)
```

## ID-нормализация

- **URL-based ID** → `{prefix}{sha256(url)}` — компактный стабильный хэш
- **Обычный ID** (arXiv, CORE) → `{prefix}{id}` — без изменений
- **id_prefix** задаётся в YAML коллектора (`cyberleninka:`, `core:`, etc.)
