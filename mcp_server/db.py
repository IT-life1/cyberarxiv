import os
import duckdb
from typing import Optional


def _db_path() -> str:
    return os.environ.get("CYBERARXIV_DB_PATH", "data/cyberarxiv.duckdb")


def _connect(db_path: str, read_only: bool = True):
    con = duckdb.connect(db_path, read_only=read_only)
    _ensure_extensions(con)
    return con


# json extension is needed for json_extract_string / json_merge_patch / json_object
# used in update_ml_tags() and get_unclassified_papers(). Autoload occasionally
# fails inside containers without network, so we install + load explicitly on
# every connection. INSTALL is a no-op once the extension is cached.
def _ensure_extensions(con) -> None:
    try:
        con.execute("INSTALL json")
    except duckdb.Error:
        pass  # already installed (or offline cache hit) — LOAD will tell us
    con.execute("LOAD json")


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
                   published_date, updated_date, tag, ml_results,
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
            "published_date", "updated_date", "tag", "ml_results",
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
                   published_date, updated_date, tag, ml_results,
                   source, language
            FROM papers WHERE paper_id = ?
            """,
            [paper_id],
        ).fetchall()
        if not rows:
            return None
        cols = [
            "paper_id", "link", "title", "authors", "abstract", "categories",
            "published_date", "updated_date", "tag", "ml_results",
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
    """Return papers without ML results, for batch ML classification."""
    if db_path is None:
        db_path = _db_path()
    if not os.path.exists(db_path):
        return []

    con = _connect(db_path)
    try:
        rows = con.execute(
            "SELECT paper_id, abstract, language FROM papers "
            "WHERE (ml_results IS NULL "
            "   OR json_extract_string(ml_results, '$.default.tag') IS NULL) "
            "AND abstract IS NOT NULL AND abstract != '' "
            "ORDER BY updated_date DESC NULLS LAST LIMIT ?",
            [limit],
        ).fetchall()
        return [{"paper_id": r[0], "abstract": r[1], "language": r[2]} for r in rows]
    finally:
        con.close()


def upsert_papers(db_path: Optional[str], rows: list[dict]) -> dict:
    """Atomically insert/update papers via a staging table.

    Each row must contain: paper_id, link, title, authors, abstract, categories,
    published_date, updated_date, source, language. Missing keys default to "".
    Returns {"inserted": int, "updated": int}.
    """
    if db_path is None:
        db_path = _db_path()
    if not rows:
        return {"inserted": 0, "updated": 0}

    # Deduplicate within the batch — keep the latest by updated_date for each id.
    by_id: dict[str, dict] = {}
    for r in rows:
        pid = r.get("paper_id")
        if not pid:
            continue
        prev = by_id.get(pid)
        if prev is None:
            by_id[pid] = r
            continue
        prev_d = prev.get("updated_date") or prev.get("published_date") or ""
        cur_d = r.get("updated_date") or r.get("published_date") or ""
        if str(cur_d) >= str(prev_d):
            by_id[pid] = r
    rows = list(by_id.values())
    if not rows:
        return {"inserted": 0, "updated": 0}

    con = _connect(db_path, read_only=False)
    try:
        _ensure_schema(con)
        con.execute("BEGIN")
        con.execute("DROP TABLE IF EXISTS stg_papers")
        con.execute("CREATE TEMP TABLE stg_papers AS SELECT * FROM papers WHERE 1=0")

        for r in rows:
            con.execute(
                """
                INSERT INTO stg_papers
                    (paper_id, link, title, authors, abstract, categories,
                     published_date, updated_date, ingested_at,
                     tag, source, language)
                VALUES
                    (?, ?, ?, ?, ?, ?,
                     TRY_CAST(? AS TIMESTAMP), TRY_CAST(? AS TIMESTAMP), now(),
                     NULL, ?, ?)
                """,
                [
                    r.get("paper_id"),
                    r.get("link", "") or "",
                    r.get("title", "") or "",
                    r.get("authors", "") or "",
                    r.get("abstract", "") or "",
                    r.get("categories", "") or "",
                    r.get("published_date"),
                    r.get("updated_date") or r.get("published_date"),
                    r.get("source", "") or "",
                    r.get("language", "") or "",
                ],
            )

        # Count first — DuckDB UPDATE/INSERT don't expose row counts via fetchone().
        updated_count = con.execute(
            """
            SELECT COUNT(*) FROM papers p JOIN stg_papers s ON p.paper_id = s.paper_id
            WHERE (p.updated_date IS NULL)
               OR (s.updated_date IS NOT NULL AND s.updated_date > p.updated_date)
            """
        ).fetchone()[0]

        inserted_count = con.execute(
            """
            SELECT COUNT(*) FROM stg_papers s
            LEFT JOIN papers p ON s.paper_id = p.paper_id
            WHERE p.paper_id IS NULL
            """
        ).fetchone()[0]

        con.execute(
            """
            UPDATE papers AS p
            SET title = s.title,
                authors = s.authors,
                abstract = s.abstract,
                categories = s.categories,
                link = s.link,
                published_date = COALESCE(s.published_date, p.published_date),
                updated_date = s.updated_date,
                language = COALESCE(NULLIF(s.language, ''), p.language),
                source = COALESCE(NULLIF(s.source, ''), p.source)
            FROM stg_papers AS s
            WHERE p.paper_id = s.paper_id
              AND (
                  p.updated_date IS NULL
                  OR (s.updated_date IS NOT NULL AND s.updated_date > p.updated_date)
              )
            """
        )

        con.execute(
            """
            INSERT INTO papers
            SELECT s.* FROM stg_papers s
            LEFT JOIN papers p ON s.paper_id = p.paper_id
            WHERE p.paper_id IS NULL
            """
        )

        con.execute("DROP TABLE stg_papers")
        con.execute("COMMIT")
        return {"inserted": int(inserted_count), "updated": int(updated_count)}
    except Exception:
        try:
            con.execute("ROLLBACK")
        except Exception:
            pass
        raise
    finally:
        con.close()


def _ensure_schema(con) -> None:
    """Create the `papers` table on the fly if the database is brand-new."""
    con.execute(
        """
        CREATE TABLE IF NOT EXISTS papers (
            paper_id        VARCHAR,
            link            VARCHAR,
            title           VARCHAR,
            authors         VARCHAR,
            abstract        VARCHAR,
            categories      VARCHAR,
            published_date  TIMESTAMP,
            updated_date    TIMESTAMP,
            ingested_at     TIMESTAMP DEFAULT now(),
            tag             VARCHAR,
            ml_results      VARCHAR,
            source          VARCHAR,
            language        VARCHAR
        )
        """
    )


def update_ml_tags(db_path: Optional[str], results: list[dict]) -> int:
    """Write ML classification results back to DuckDB as JSON. Returns number of updated rows."""
    if db_path is None:
        db_path = _db_path()
    if not results:
        return 0

    con = _connect(db_path, read_only=False)
    try:
        updated = 0
        for r in results:
            con.execute(
                """
                UPDATE papers
                SET ml_results = json_merge_patch(
                    COALESCE(ml_results, '{}'),
                    json_object('default', json_object(
                        'tag', ?,
                        'confidence', CAST(? AS DOUBLE)
                    ))
                )
                WHERE paper_id = ?
                """,
                [r["tag"], r["confidence"], r["paper_id"]],
            )
            updated += 1
        return updated
    finally:
        con.close()
