"""
CyberArXiv MCP Server
=====================
Предоставляет AI-ассистентам (Claude Desktop и др.) инструменты для работы
с базой данных научных статей по кибербезопасности.

Запуск: python server.py
Подключение: настроить Claude Desktop (см. docs/superpowers/specs/)
"""

import json
import os
from typing import Optional

from mcp.server.fastmcp import FastMCP
import db
import fetchers
import ml_client

mcp = FastMCP(
    "cyberarxiv",
    host=os.environ.get("MCP_HOST", "127.0.0.1"),
    port=int(os.environ.get("MCP_PORT", "8000")),
)


def _db() -> str:
    return os.environ.get("CYBERARXIV_DB_PATH", "data/cyberarxiv.duckdb")


# ─── Инструменты чтения ────────────────────────────────────────────────────

def tool_search_papers(
    query: str = "",
    category: str = "",
    year: Optional[int] = None,
    source: str = "",
    language: str = "",
    limit: int = 20,
) -> str:
    results = db.search_papers(
        db_path=_db(),
        query=query,
        category=category,
        year=year,
        source=source,
        language=language,
        limit=limit,
    )
    for r in results:
        for k, v in r.items():
            if hasattr(v, "isoformat"):
                r[k] = v.isoformat()
    return json.dumps(results, ensure_ascii=False)


def tool_get_paper(paper_id: str) -> str:
    paper = db.get_paper(db_path=_db(), paper_id=paper_id)
    if paper:
        for k, v in paper.items():
            if hasattr(v, "isoformat"):
                paper[k] = v.isoformat()
    return json.dumps(paper, ensure_ascii=False)


def tool_get_stats() -> str:
    stats = db.get_stats(db_path=_db())
    return json.dumps(stats, ensure_ascii=False)


def tool_get_categories() -> str:
    cats = db.get_categories(db_path=_db())
    return json.dumps(cats, ensure_ascii=False)


# ─── Инструменты ML ────────────────────────────────────────────────────────

def tool_classify_paper(abstract: str, language: str = "en") -> str:
    result = ml_client.classify_paper(abstract=abstract, language=language)
    return json.dumps(result, ensure_ascii=False)


def tool_run_ml_batch(only_new: bool = True, limit: int = 100) -> str:
    papers = db.get_unclassified_papers(db_path=_db(), limit=limit)
    if not only_new:
        papers = db.search_papers(db_path=_db(), limit=limit)

    if not papers:
        return json.dumps({
            "status": "ok",
            "message": "Нет статей для классификации",
            "updated": 0,
            "unclassified_by_language": {},
        })

    results = ml_client.classify_batch(papers)
    if not results:
        return json.dumps({
            "status": "error",
            "message": "ML сервис недоступен или вернул пустой результат",
            "updated": 0,
            "unclassified_by_language": {},
        })

    # Group papers that did not receive a tag by language. Most often this
    # means no model is loaded for that language, but it can also be any
    # classification failure — surface the count so the caller can act.
    lang_by_id = {p["paper_id"]: (p.get("language") or "unknown") for p in papers}
    unclassified_by_language: dict[str, int] = {}
    for r in results:
        if not r.get("tag"):
            lang = lang_by_id.get(r.get("paper_id"), "unknown")
            unclassified_by_language[lang] = unclassified_by_language.get(lang, 0) + 1

    updated = db.update_ml_tags(db_path=_db(), results=results)

    msg = f"Классифицировано {updated} статей"
    if unclassified_by_language:
        summary = ", ".join(f"{k}={v}" for k, v in sorted(unclassified_by_language.items()))
        msg += f"; не классифицировано (нет модели для языка): {summary}"

    return json.dumps({
        "status": "ok",
        "updated": updated,
        "unclassified_by_language": unclassified_by_language,
        "message": msg,
    }, ensure_ascii=False)


# ─── Регистрация инструментов в MCP ───────────────────────────────────────

@mcp.tool()
def search_papers(
    query: str = "",
    category: str = "",
    year: Optional[int] = None,
    source: str = "",
    language: str = "",
    limit: int = 20,
) -> str:
    """Поиск статей по кибербезопасности в базе данных.
    Фильтры: query (текст в заголовке/аннотации), category (тема),
    year (год публикации), source (arxiv/cyberleninka/core),
    language (en/ru), limit (макс. результатов, default 20)."""
    return tool_search_papers(query=query, category=category, year=year,
                               source=source, language=language, limit=limit)


@mcp.tool()
def get_paper(paper_id: str) -> str:
    """Получить полную информацию о статье по её ID."""
    return tool_get_paper(paper_id=paper_id)


@mcp.tool()
def get_stats() -> str:
    """Статистика базы: кол-во статей по источникам, темам, языкам, годам."""
    return tool_get_stats()


@mcp.tool()
def get_categories() -> str:
    """Список всех доступных тематических категорий в базе."""
    return tool_get_categories()


@mcp.tool()
def classify_paper(abstract: str, language: str = "en") -> str:
    """Классифицировать текст аннотации через ML-модель.
    Возвращает тему (tag), уверенность (confidence) и все оценки (all_scores).
    language: 'en' или 'ru'."""
    return tool_classify_paper(abstract=abstract, language=language)


@mcp.tool()
def run_ml_batch(only_new: bool = True, limit: int = 100) -> str:
    """Запустить ML-классификацию для статей в базе.
    only_new=True (default): только статьи без ml_tag.
    limit: максимальное количество статей (default 100).
    Результаты сохраняются в DuckDB."""
    return tool_run_ml_batch(only_new=only_new, limit=limit)


# ─── Инструменты загрузки извне ────────────────────────────────────────────

def _fetch_and_store(rows: list[dict], source: str) -> dict:
    if not rows:
        return {"status": "ok", "source": source, "fetched": 0, "inserted": 0, "updated": 0,
                "message": "Внешний источник не вернул результатов"}
    res = db.upsert_papers(db_path=_db(), rows=rows)
    return {
        "status": "ok",
        "source": source,
        "fetched": len(rows),
        "inserted": res["inserted"],
        "updated": res["updated"],
        "message": f"{source}: получено {len(rows)}, добавлено {res['inserted']}, обновлено {res['updated']}",
    }


@mcp.tool()
def fetch_arxiv(query: str = "", max_results: int = 50) -> str:
    """Скачать статьи с arXiv (Atom API) и сохранить в БД.

    query: search_query в формате arXiv (например, 'cat:cs.CR AND all:malware').
           Пусто → дефолтный фильтр по кибербезопасности (cs.CR/cs.NI/cs.LG).
    max_results: сколько максимум статей загрузить (default 50, hard cap arXiv = 30000).
    """
    try:
        rows = fetchers.fetch_arxiv(query=query, max_results=int(max_results))
    except Exception as exc:
        return json.dumps({"status": "error", "source": "arxiv", "message": str(exc)},
                          ensure_ascii=False)
    return json.dumps(_fetch_and_store(rows, "arxiv"), ensure_ascii=False)


@mcp.tool()
def fetch_cyberleninka(set_spec: str = "journal_32131", max_results: int = 50) -> str:
    """[EXPERIMENTAL] Скачать статьи с КиберЛенинки (OAI-PMH) и сохранить в БД.

    Известное ограничение: OAI-PMH-фид КиберЛенинки в большинстве записей
    не отдаёт `dc:description` (аннотацию), поэтому ML-классификатор по теме
    работает плохо — у большинства статей в базе после такого fetch будет
    только заголовок. Используйте, если нужны метаданные/ссылки, а не
    тематическая классификация.

    set_spec: OAI set (default 'journal_32131' — «Вопросы кибербезопасности»).
    max_results: сколько максимум статей загрузить (default 50).
    """
    try:
        rows = fetchers.fetch_cyberleninka(set_spec=set_spec, max_results=int(max_results))
    except Exception as exc:
        return json.dumps({"status": "error", "source": "cyberleninka", "message": str(exc)},
                          ensure_ascii=False)
    return json.dumps(_fetch_and_store(rows, "cyberleninka"), ensure_ascii=False)


@mcp.tool()
def fetch_core(query: str = "", max_results: int = 50) -> str:
    """Скачать статьи с CORE API v3 и сохранить в БД.

    Требуется env CORE_API_KEY (бесплатно: https://core.ac.uk/services/api).
    query: текстовый запрос (default — кибербезопасность).
    max_results: сколько максимум статей загрузить (default 50).
    """
    try:
        rows = fetchers.fetch_core(query=query, max_results=int(max_results))
    except Exception as exc:
        return json.dumps({"status": "error", "source": "core", "message": str(exc)},
                          ensure_ascii=False)
    return json.dumps(_fetch_and_store(rows, "core"), ensure_ascii=False)


@mcp.tool()
def fetch_by_url(url: str) -> str:
    """Скачать одну статью по URL или DOI и сохранить в БД.

    Поддерживается:
      * https://arxiv.org/abs/<id>  или  arxiv.org/pdf/<id>
      * https://doi.org/<doi>  /  doi:<doi>  /  голый DOI '10.x/y'
    """
    try:
        row = fetchers.fetch_by_url(url)
    except Exception as exc:
        return json.dumps({"status": "error", "source": "url", "message": str(exc)},
                          ensure_ascii=False)
    if not row:
        return json.dumps({"status": "ok", "source": "url", "fetched": 0, "inserted": 0,
                           "updated": 0, "message": "Не удалось получить метаданные"},
                          ensure_ascii=False)
    return json.dumps(_fetch_and_store([row], row.get("source", "url")), ensure_ascii=False)


if __name__ == "__main__":
    # MCP_TRANSPORT: stdio (default, Claude Desktop) | streamable-http | sse
    transport = os.environ.get("MCP_TRANSPORT", "stdio")
    if transport == "stdio":
        mcp.run()
    else:
        mcp.run(transport=transport)
