import os
from typing import Optional

import httpx

ML_SERVICE_URL = os.environ.get("ML_SERVICE_URL", "http://localhost:5001")
DEFAULT_TIMEOUT = 30.0


def _ml_url(path: str) -> str:
    return f"{ML_SERVICE_URL.rstrip('/')}{path}"


def classify_paper(
    text: str,
    language: str = "en",
    model: Optional[str] = None,
    paper_id: str = "adhoc",
) -> dict:
    """Classify a single abstract via /classify_single.

    Returns a dict with 'tag', 'confidence', 'all_scores' on success,
    or {'error': <message>} when the service is unavailable.
    """
    params = {}
    if model:
        params["model"] = model

    payload = {"id": paper_id, "abstract": text}

    try:
        response = httpx.post(
            _ml_url("/classify_single"),
            json=payload,
            params=params,
            timeout=DEFAULT_TIMEOUT,
        )
        response.raise_for_status()
        data = response.json()
        return {
            "tag": data.get("tag"),
            "confidence": data.get("confidence"),
            "all_scores": data.get("all_scores"),
            "model_used": data.get("model_used"),
            "error": None,
        }
    except Exception as exc:
        return {"tag": None, "confidence": None, "all_scores": None, "model_used": None, "error": str(exc)}


def classify_batch(
    papers: list[dict],
    model: Optional[str] = None,
) -> list[dict]:
    """Classify a batch of papers via /classify.

    Each item in `papers` must have keys: paper_id, abstract, language.
    Returns a list of dicts with paper_id, tag, confidence merged together.
    """
    params = {}
    if model:
        params["model"] = model

    payload = {"papers": [{"id": p["paper_id"], "abstract": p.get("abstract", "")} for p in papers]}

    response = httpx.post(
        _ml_url("/classify"),
        json=payload,
        params=params,
        timeout=DEFAULT_TIMEOUT,
    )
    response.raise_for_status()
    data = response.json()

    results_by_id = {r["id"]: r for r in data.get("results", [])}
    output = []
    for paper in papers:
        pid = paper["paper_id"]
        r = results_by_id.get(pid, {})
        output.append({
            "paper_id": pid,
            "tag": r.get("tag"),
            "confidence": r.get("confidence"),
            "all_scores": r.get("all_scores"),
            "model_used": data.get("model_used"),
        })
    return output


def get_available_models(base_url: Optional[str] = None) -> dict:
    """Return the models dict from /models endpoint.

    Keys are model names, values are their metadata dicts.
    """
    url = _ml_url("/models") if base_url is None else f"{base_url.rstrip('/')}/models"
    response = httpx.get(url, timeout=DEFAULT_TIMEOUT)
    response.raise_for_status()
    data = response.json()
    return data.get("models", {})
