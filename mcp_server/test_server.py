import os, sys, json, tempfile, pytest
sys.path.insert(0, os.path.dirname(__file__))

@pytest.fixture(autouse=True)
def set_db_env(tmp_path):
    import duckdb
    db_file = str(tmp_path / "test.duckdb")
    con = duckdb.connect(db_file)
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
            'test_001', 'http://example.com', 'Test Paper', 'Author',
            'This is about ransomware', 'Malware',
            '2024-01-01', '2024-01-01', NOW(), 'Malware',
            NULL, NULL, 'arxiv', 'en'
        )
    """)
    con.close()
    os.environ["CYBERARXIV_DB_PATH"] = db_file
    yield
    os.environ.pop("CYBERARXIV_DB_PATH", None)

def test_tool_search_papers():
    from server import tool_search_papers
    result = json.loads(tool_search_papers(query="ransomware"))
    assert len(result) == 1
    assert result[0]["paper_id"] == "test_001"

def test_tool_get_paper_found():
    from server import tool_get_paper
    result = json.loads(tool_get_paper(paper_id="test_001"))
    assert result["title"] == "Test Paper"

def test_tool_get_paper_not_found():
    from server import tool_get_paper
    result = json.loads(tool_get_paper(paper_id="nonexistent"))
    assert result is None

def test_tool_get_stats():
    from server import tool_get_stats
    result = json.loads(tool_get_stats())
    assert result["total"] == 1
    assert "by_source" in result

def test_tool_get_categories():
    from server import tool_get_categories
    result = json.loads(tool_get_categories())
    assert "Malware" in result
