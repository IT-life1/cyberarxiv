import os, sys, pytest
sys.path.insert(0, os.path.dirname(__file__))
from unittest.mock import patch, MagicMock

def test_classify_paper_success():
    from ml_client import classify_paper
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {
        "model_used": "best_model",
        "id": "p1",
        "tag": "Malware",
        "confidence": 0.92,
        "all_scores": {"Malware": 0.92, "Other": 0.08},
    }
    with patch("httpx.post", return_value=mock_response):
        result = classify_paper("ransomware encrypts files", language="en")
    assert result["tag"] == "Malware"
    assert result["confidence"] == 0.92

def test_classify_paper_service_unavailable():
    from ml_client import classify_paper
    import httpx
    with patch("httpx.post", side_effect=httpx.ConnectError("refused")):
        result = classify_paper("some text")
    assert result["error"] is not None

def test_classify_batch_success():
    from ml_client import classify_batch
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {
        "model_used": "best_model",
        "results": [
            {"id": "p1", "tag": "Malware", "confidence": 0.9},
            {"id": "p2", "tag": "Network", "confidence": 0.8},
        ],
    }
    with patch("httpx.post", return_value=mock_response):
        results = classify_batch([
            {"paper_id": "p1", "abstract": "ransomware", "language": "en"},
            {"paper_id": "p2", "abstract": "firewall", "language": "en"},
        ])
    assert len(results) == 2
    assert results[0]["paper_id"] == "p1"

def test_get_available_models_success():
    from ml_client import get_available_models
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {
        "models": {"best_model": {"num_classes": 16}},
        "default": "best_model",
    }
    with patch("httpx.get", return_value=mock_response):
        models = get_available_models()
    assert "best_model" in models
