import os, sys, tempfile, json, pytest
sys.path.insert(0, os.path.dirname(__file__))

def make_test_db():
    import duckdb
    tmp = tempfile.NamedTemporaryFile(suffix=".duckdb", delete=False)
    tmp.close()
    os.unlink(tmp.name)  # DuckDB must create its own file, not open a pre-created empty one
    con = duckdb.connect(tmp.name)
    con.execute("""
        CREATE TABLE papers (
            paper_id VARCHAR, link VARCHAR, title VARCHAR, authors VARCHAR,
            abstract VARCHAR, categories VARCHAR,
            published_date TIMESTAMP, updated_date TIMESTAMP,
            ingested_at TIMESTAMP, tag VARCHAR,
            ml_tag VARCHAR, ml_confidence DOUBLE,
            source VARCHAR, language VARCHAR
        )
    """)
    con.execute("""
        INSERT INTO papers VALUES (
            'arxiv_001', 'https://arxiv.org/abs/001',
            'Ransomware Detection', 'Alice, Bob',
            'We detect ransomware using ML', 'Malware',
            '2024-01-15', '2024-01-15', NOW(), 'Malware',
            'Malware', 0.95, 'arxiv', 'en'
        )
    """)
    con.execute("""
        INSERT INTO papers VALUES (
            'cyrleninka_002', 'https://cyberleninka.ru/002',
            'Обнаружение вирусов', 'Иванов И.И.',
            'Метод обнаружения вирусов', 'Malware',
            '2024-02-10', '2024-02-10', NOW(), 'Malware',
            NULL, NULL, 'cyberleninka', 'ru'
        )
    """)
    con.close()
    return tmp.name

def test_search_papers_no_filter(tmp_db):
    from db import search_papers
    results = search_papers(tmp_db)
    assert len(results) == 2

def test_search_papers_by_language(tmp_db):
    from db import search_papers
    results = search_papers(tmp_db, language="ru")
    assert len(results) == 1
    assert results[0]["paper_id"] == "cyrleninka_002"

def test_search_papers_by_text(tmp_db):
    from db import search_papers
    results = search_papers(tmp_db, query="ransomware")
    assert len(results) == 1
    assert results[0]["paper_id"] == "arxiv_001"

def test_get_paper_found(tmp_db):
    from db import get_paper
    paper = get_paper(tmp_db, "arxiv_001")
    assert paper is not None
    assert paper["title"] == "Ransomware Detection"

def test_get_paper_not_found(tmp_db):
    from db import get_paper
    paper = get_paper(tmp_db, "nonexistent")
    assert paper is None

def test_get_stats(tmp_db):
    from db import get_stats
    stats = get_stats(tmp_db)
    assert stats["total"] == 2
    assert "by_source" in stats
    assert "by_tag" in stats
    assert "by_language" in stats

def test_get_categories(tmp_db):
    from db import get_categories
    cats = get_categories(tmp_db)
    assert "Malware" in cats

@pytest.fixture
def tmp_db():
    path = make_test_db()
    yield path
    import os; os.unlink(path)
