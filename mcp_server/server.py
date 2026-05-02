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
import ml_client

mcp = FastMCP("cyberarxiv")


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
        return json.dumps({"status": "ok", "message": "Нет статей для классификации", "updated": 0})

    results = ml_client.classify_batch(papers)
    if not results:
        return json.dumps({"status": "error", "message": "ML сервис недоступен или вернул пустой результат", "updated": 0})

    updated = db.update_ml_tags(db_path=_db(), results=results)
    return json.dumps({"status": "ok", "updated": updated, "message": f"Классифицировано {updated} статей"})


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


if __name__ == "__main__":
    mcp.run()
