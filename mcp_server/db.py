import os
import duckdb
from typing import Optional


def _db_path() -> str:
    return os.environ.get("CYBERARXIV_DB_PATH", "data/cyberarxiv.duckdb")


def _connect(db_path: str, read_only: bool = True):
    return duckdb.connect(db_path, read_only=read_only)


def search_papers(
    db_path: Optional[str] = None,
    query: str = "",
    category: str = "",
    year: Optional[int] = None,
    source: str = "",
    language: str = "",
    limit: int = 20,
) -> list[dict]:
    if db_path is None:
        db_path = _db_path()
    if not os.path.exists(db_path):
        return []

    con = _connect(db_path)
    try:
        sql = """
            SELECT paper_id, link, title, authors, abstract, categories,
                   published_date, updated_date, tag, ml_tag, ml_confidence,
                   source, language
            FROM papers
            WHERE 1=1
        """
        params = []
        if query:
            sql += " AND (lower(title) LIKE ? OR lower(abstract) LIKE ?)"
            pat = f"%{query.lower()}%"
            params += [pat, pat]
        if category:
            sql += " AND lower(categories) LIKE ?"
            params.append(f"%{category.lower()}%")
        if year:
            sql += " AND EXTRACT(year FROM published_date) = ?"
            params.append(int(year))
        if source:
            sql += " AND source = ?"
            params.append(source)
        if language:
            sql += " AND language = ?"
            params.append(language)
        sql += " ORDER BY updated_date DESC NULLS LAST LIMIT ?"
        params.append(limit)

        rows = con.execute(sql, params).fetchall()
        cols = [
            "paper_id", "link", "title", "authors", "abstract", "categories",
            "published_date", "updated_date", "tag", "ml_tag", "ml_confidence",
            "source", "language",
        ]
        return [dict(zip(cols, row)) for row in rows]
    finally:
        con.close()


def get_paper(db_path: Optional[str], paper_id: str) -> Optional[dict]:
    if db_path is None:
        db_path = _db_path()
    if not os.path.exists(db_path):
        return None

    con = _connect(db_path)
    try:
        rows = con.execute(
            """
            SELECT paper_id, link, title, authors, abstract, categories,
                   published_date, updated_date, tag, ml_tag, ml_confidence,
                   source, language
            FROM papers WHERE paper_id = ?
            """,
            [paper_id],
        ).fetchall()
        if not rows:
            return None
        cols = [
            "paper_id", "link", "title", "authors", "abstract", "categories",
            "published_date", "updated_date", "tag", "ml_tag", "ml_confidence",
            "source", "language",
        ]
        return dict(zip(cols, rows[0]))
    finally:
        con.close()


def get_stats(db_path: Optional[str] = None) -> dict:
    if db_path is None:
        db_path = _db_path()
    if not os.path.exists(db_path):
        return {"total": 0, "by_source": {}, "by_tag": {}, "by_language": {}, "by_year": {}}

    con = _connect(db_path)
    try:
        total = con.execute("SELECT COUNT(*) FROM papers").fetchone()[0]

        by_source = {
            row[0]: row[1]
            for row in con.execute(
                "SELECT source, COUNT(*) FROM papers GROUP BY source ORDER BY 2 DESC"
            ).fetchall()
            if row[0]
        }
        by_tag = {
            row[0]: row[1]
            for row in con.execute(
                "SELECT tag, COUNT(*) FROM papers WHERE tag IS NOT NULL GROUP BY tag ORDER BY 2 DESC"
            ).fetchall()
        }
        by_language = {
            row[0]: row[1]
            for row in con.execute(
                "SELECT language, COUNT(*) FROM papers GROUP BY language ORDER BY 2 DESC"
            ).fetchall()
            if row[0]
        }
        by_year = {
            str(int(row[0])): row[1]
            for row in con.execute(
                "SELECT EXTRACT(year FROM published_date), COUNT(*) FROM papers "
                "WHERE published_date IS NOT NULL GROUP BY 1 ORDER BY 1 DESC"
            ).fetchall()
            if row[0]
        }
        return {
            "total": total,
            "by_source": by_source,
            "by_tag": by_tag,
            "by_language": by_language,
            "by_year": by_year,
        }
    finally:
        con.close()


def get_categories(db_path: Optional[str] = None) -> list[str]:
    if db_path is None:
        db_path = _db_path()
    if not os.path.exists(db_path):
        return []

    con = _connect(db_path)
    try:
        rows = con.execute(
            "SELECT DISTINCT tag FROM papers WHERE tag IS NOT NULL ORDER BY tag"
        ).fetchall()
        return [row[0] for row in rows]
    finally:
        con.close()


def get_unclassified_papers(db_path: Optional[str], limit: int = 100) -> list[dict]:
    """Return papers without ml_tag, for batch ML classification."""
    if db_path is None:
        db_path = _db_path()
    if not os.path.exists(db_path):
        return []

    con = _connect(db_path)
    try:
        rows = con.execute(
            "SELECT paper_id, abstract, language FROM papers "
            "WHERE ml_tag IS NULL AND abstract IS NOT NULL AND abstract != '' "
            "ORDER BY updated_date DESC NULLS LAST LIMIT ?",
            [limit],
        ).fetchall()
        return [{"paper_id": r[0], "abstract": r[1], "language": r[2]} for r in rows]
    finally:
        con.close()


def update_ml_tags(db_path: Optional[str], results: list[dict]) -> int:
    """Write ML classification results back to DuckDB. Returns number of updated rows."""
    if db_path is None:
        db_path = _db_path()
    if not results:
        return 0

    con = _connect(db_path, read_only=False)
    try:
        updated = 0
        for r in results:
            con.execute(
                "UPDATE papers SET ml_tag = ?, ml_confidence = ? WHERE paper_id = ?",
                [r["tag"], r["confidence"], r["paper_id"]],
            )
            updated += 1
        return updated
    finally:
        con.close()
