"""Collect raw (unlabeled) papers from arXiv via the Atom API.

Designed for the training pipeline — produces a parquet file with columns:
    id, title, abstract, authors, primary_category, published, link

arXiv soft-caps `max_results` at ~2000 per request and recommends 3s between
requests. We page through with `start` offsets until we hit `target` rows or
the API stops returning new entries. For 70k+ rows be patient: ~20 minutes.
"""
from __future__ import annotations

import logging
import re
import time
from datetime import datetime
from pathlib import Path
from typing import Callable, List, Optional
from xml.etree import ElementTree as ET

import pandas as pd
import requests

log = logging.getLogger(__name__)

ARXIV_API = "https://export.arxiv.org/api/query"
NS = {"atom": "http://www.w3.org/2005/Atom",
      "arxiv": "http://arxiv.org/schemas/atom"}

DEFAULT_QUERY = (
    "(cat:cs.CR OR cat:cs.NI OR cat:cs.LG) AND "
    "all:(security OR malware OR intrusion OR attack OR cryptography "
    "OR phishing OR exploit OR vulnerability OR adversarial OR botnet)"
)


def _strip(s: Optional[str]) -> str:
    if not s:
        return ""
    return re.sub(r"\s+", " ", s).strip()


def _parse_entry(entry: ET.Element) -> Optional[dict]:
    id_el = entry.find("atom:id", NS)
    title_el = entry.find("atom:title", NS)
    summary_el = entry.find("atom:summary", NS)
    pub_el = entry.find("atom:published", NS)
    authors = entry.findall("atom:author/atom:name", NS)
    primary = entry.find("arxiv:primary_category", NS)
    if primary is None:
        primary = entry.find("atom:category", NS)

    aid = _strip(id_el.text) if id_el is not None else ""
    title = _strip(title_el.text) if title_el is not None else ""
    abstract = _strip(summary_el.text) if summary_el is not None else ""

    if not aid or not title or not abstract:
        return None

    arxiv_id = aid.rsplit("/", 1)[-1]
    arxiv_id = re.sub(r"v\d+$", "", arxiv_id)

    return {
        "id": arxiv_id,
        "title": title,
        "abstract": abstract,
        "authors": "; ".join(_strip(a.text) for a in authors if a.text),
        "primary_category": primary.attrib.get("term", "") if primary is not None else "",
        "published": _strip(pub_el.text) if pub_el is not None else "",
        "link": aid,
    }


def collect_arxiv(
    target: int,
    query: str = DEFAULT_QUERY,
    page_size: int = 200,
    sleep_secs: float = 3.0,
    output_path: Optional[Path] = None,
    progress_cb: Optional[Callable[[int, int, str], None]] = None,
) -> Path:
    """Fetch up to `target` arXiv papers and save to parquet.

    progress_cb(fetched, target, message) is invoked after every page so the
    UI/job-store can stream progress. Tolerates transient network failures
    by retrying twice per page.
    """
    if target <= 0:
        raise ValueError("target must be positive")

    page_size = max(1, min(page_size, 2000))
    out: List[dict] = []
    seen = set()
    start = 0
    consecutive_empty = 0

    while len(out) < target:
        want = min(page_size, target - len(out))
        params = {
            "search_query": query,
            "start": start,
            "max_results": want,
            "sortBy": "submittedDate",
            "sortOrder": "descending",
        }
        log.info("arxiv: requesting start=%d max_results=%d (have %d/%d)",
                 start, want, len(out), target)

        last_err: Optional[Exception] = None
        text: Optional[str] = None
        for attempt in range(3):
            try:
                resp = requests.get(ARXIV_API, params=params, timeout=60)
                resp.raise_for_status()
                text = resp.text
                break
            except Exception as e:
                last_err = e
                log.warning("arxiv: attempt %d failed: %s", attempt + 1, e)
                time.sleep(sleep_secs * (attempt + 1))

        if text is None:
            raise RuntimeError(f"arXiv request failed after retries: {last_err}")

        try:
            root = ET.fromstring(text)
        except ET.ParseError as e:
            raise RuntimeError(f"arXiv XML parse error: {e}")

        entries = root.findall("atom:entry", NS)
        if not entries:
            consecutive_empty += 1
            if consecutive_empty >= 2:
                log.info("arxiv: two empty pages in a row, stopping")
                break
        else:
            consecutive_empty = 0

        added = 0
        for ent in entries:
            row = _parse_entry(ent)
            if row is None:
                continue
            if row["id"] in seen:
                continue
            seen.add(row["id"])
            out.append(row)
            added += 1
            if len(out) >= target:
                break

        log.info("arxiv: page parsed=%d added=%d total=%d", len(entries), added, len(out))
        if progress_cb:
            progress_cb(len(out), target, f"page start={start}: +{added}, total={len(out)}")

        start += page_size
        if added == 0 and len(entries) > 0:
            # API returned only duplicates; try jumping further
            start += page_size

        if len(out) >= target:
            break

        time.sleep(sleep_secs)

    df = pd.DataFrame(out)
    if df.empty:
        raise RuntimeError("arXiv returned 0 usable papers — check your query")

    df = df.drop_duplicates(subset=["id"]).reset_index(drop=True)

    if output_path is None:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        output_path = Path(f"arxiv_{ts}_{len(df)}.parquet")

    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    df.to_parquet(output_path, index=False)

    log.info("arxiv: saved %d rows to %s", len(df), output_path)
    return output_path
