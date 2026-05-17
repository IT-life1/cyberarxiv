"""
External-source fetchers for CyberArXiv MCP.

Each fetcher returns a list of dicts with the unified schema:
    paper_id, link, title, authors, abstract, categories,
    published_date, updated_date, source, language

These dicts can be passed straight to db.upsert_papers().
"""
from __future__ import annotations

import hashlib
import os
import re
import time
from datetime import datetime
from typing import Optional, Iterable
from xml.etree import ElementTree as ET

import httpx

USER_AGENT = "cyberarxiv-mcp/0.1 (+https://github.com/cyberarxiv)"
DEFAULT_TIMEOUT = 30.0


# ─── Common helpers ───────────────────────────────────────────────────────────

def _detect_language(text: str) -> str:
    if not text:
        return ""
    cyr = len(re.findall(r"[Ѐ-ӿ]", text))
    lat = len(re.findall(r"[A-Za-z]", text))
    total = cyr + lat
    if total == 0:
        return ""
    return "ru" if cyr / total > 0.25 else "en"


def _sha256(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def _make_id(prefix: str, raw: str) -> str:
    if re.match(r"^https?://", raw, re.IGNORECASE):
        return f"{prefix}{_sha256(raw)}"
    return f"{prefix}{raw}"


def _norm(s: Optional[str]) -> str:
    if s is None:
        return ""
    return re.sub(r"\s+", " ", str(s)).strip()


def _empty_record(paper_id: str, source: str) -> dict:
    return {
        "paper_id": paper_id,
        "link": "",
        "title": "",
        "authors": "",
        "abstract": "",
        "categories": "",
        "published_date": None,
        "updated_date": None,
        "source": source,
        "language": "",
    }


# ─── arXiv (Atom API) ─────────────────────────────────────────────────────────

ATOM_NS = {"atom": "http://www.w3.org/2005/Atom"}
ARXIV_BASE = "https://export.arxiv.org/api/query"


def _arxiv_default_query() -> str:
    now = datetime.utcnow().strftime("%Y%m%d%H%M")
    return (
        "(cat:cs.CR OR cat:cs.NI OR cat:cs.LG) "
        "AND all:(malware OR intrusion OR attack OR threat OR adversary "
        "OR botnet OR exploit OR trojan OR phishing) "
        f"AND submittedDate:[202001010000 TO {now}]"
    )


def fetch_arxiv(query: str = "", max_results: int = 50) -> list[dict]:
    """Fetch papers from arXiv Atom API."""
    if max_results < 1:
        return []
    search_query = query or _arxiv_default_query()

    out: list[dict] = []
    seen: set[str] = set()
    start = 0
    page = min(100, max_results)

    with httpx.Client(timeout=DEFAULT_TIMEOUT, headers={"User-Agent": USER_AGENT}) as client:
        while len(out) < max_results:
            n = min(page, max_results - len(out))
            try:
                resp = client.get(
                    ARXIV_BASE,
                    params={
                        "search_query": search_query,
                        "start": start,
                        "max_results": n,
                        "sortBy": "submittedDate",
                        "sortOrder": "descending",
                    },
                )
                resp.raise_for_status()
            except httpx.HTTPError as exc:
                raise RuntimeError(f"arXiv API request failed at start={start}: {exc}") from exc

            entries = _parse_arxiv_atom(resp.content)
            if not entries:
                break

            fresh = 0
            for r in entries:
                if r["paper_id"] in seen:
                    continue
                seen.add(r["paper_id"])
                out.append(r)
                fresh += 1
                if len(out) >= max_results:
                    break
            if fresh == 0:
                break
            start += len(entries)
            time.sleep(0.3)
    return out


def _parse_arxiv_atom(xml_bytes: bytes) -> list[dict]:
    root = ET.fromstring(xml_bytes)
    rows: list[dict] = []
    for e in root.findall("atom:entry", ATOM_NS):
        atom_id = _norm((e.findtext("atom:id", default="", namespaces=ATOM_NS) or ""))
        if not atom_id:
            continue
        # arxiv id like 2401.12345  (strip version suffix)
        raw_id = re.sub(r"^.*/abs/", "", atom_id)
        raw_id = re.sub(r"v\d+$", "", raw_id)
        title = _norm(e.findtext("atom:title", default="", namespaces=ATOM_NS))
        abstract = _norm(e.findtext("atom:summary", default="", namespaces=ATOM_NS))
        published = _norm(e.findtext("atom:published", default="", namespaces=ATOM_NS))
        updated = _norm(e.findtext("atom:updated", default="", namespaces=ATOM_NS))
        authors = "; ".join(
            _norm(a.findtext("atom:name", default="", namespaces=ATOM_NS))
            for a in e.findall("atom:author", ATOM_NS)
        )
        categories = "; ".join(
            (c.attrib.get("term") or "").strip()
            for c in e.findall("atom:category", ATOM_NS)
            if c.attrib.get("term")
        )
        rows.append({
            "paper_id": raw_id,
            "link": atom_id,
            "title": title,
            "authors": authors,
            "abstract": abstract,
            "categories": categories,
            "published_date": published or None,
            "updated_date": updated or published or None,
            "source": "arxiv",
            "language": "en",
        })
    return rows


# ─── CyberLeninka (OAI-PMH) ───────────────────────────────────────────────────

CL_BASE = "https://cyberleninka.ru/oai"
CL_DEFAULT_SET = "journal_32131"  # «Вопросы кибербезопасности»

OAI_NS = {
    "oai": "http://www.openarchives.org/OAI/2.0/",
    "dc": "http://purl.org/dc/elements/1.1/",
    "oai_dc": "http://www.openarchives.org/OAI/2.0/oai_dc/",
}


def fetch_cyberleninka(set_spec: str = CL_DEFAULT_SET, max_results: int = 50) -> list[dict]:
    """Fetch papers from CyberLeninka via OAI-PMH (oai_dc)."""
    if max_results < 1:
        return []

    out: list[dict] = []
    token: Optional[str] = None
    params: dict[str, str] = {
        "verb": "ListRecords",
        "metadataPrefix": "oai_dc",
        "set": set_spec,
    }

    with httpx.Client(timeout=DEFAULT_TIMEOUT, headers={"User-Agent": USER_AGENT}) as client:
        while len(out) < max_results:
            try:
                resp = client.get(CL_BASE, params=params)
                resp.raise_for_status()
            except httpx.HTTPError as exc:
                raise RuntimeError(f"CyberLeninka OAI request failed: {exc}") from exc

            try:
                root = ET.fromstring(resp.content)
            except ET.ParseError as exc:
                raise RuntimeError(f"CyberLeninka OAI XML parse error: {exc}") from exc

            records = root.findall(".//oai:ListRecords/oai:record", OAI_NS)
            if not records:
                break

            for rec in records:
                row = _parse_cyberleninka_record(rec)
                if row:
                    out.append(row)
                    if len(out) >= max_results:
                        break

            token_el = root.find(".//oai:ListRecords/oai:resumptionToken", OAI_NS)
            token = (token_el.text or "").strip() if token_el is not None else ""
            if not token or len(out) >= max_results:
                break
            params = {"verb": "ListRecords", "resumptionToken": token}
            time.sleep(1.0)
    return out


def _parse_cyberleninka_record(rec: ET.Element) -> Optional[dict]:
    header = rec.find("oai:header", OAI_NS)
    if header is None or (header.attrib.get("status") == "deleted"):
        return None
    identifier = _norm(header.findtext("oai:identifier", default="", namespaces=OAI_NS))
    datestamp = _norm(header.findtext("oai:datestamp", default="", namespaces=OAI_NS))
    if not identifier:
        return None

    meta = rec.find(".//oai_dc:dc", OAI_NS)
    if meta is None:
        return None

    def _dc_all(tag: str) -> list[str]:
        return [_norm(el.text) for el in meta.findall(f"dc:{tag}", OAI_NS) if el.text]

    def _dc_first(tag: str) -> str:
        vals = _dc_all(tag)
        return vals[0] if vals else ""

    title = _dc_first("title")
    abstract = _dc_first("description")
    authors = "; ".join(_dc_all("creator"))
    categories = "; ".join(_dc_all("subject"))
    published = _dc_first("date")
    # «identifier» dc-полей часто содержит http-ссылку на статью
    link = ""
    for v in _dc_all("identifier"):
        if v.startswith("http"):
            link = v
            break
    if not title or not link:
        return None

    paper_id = _make_id("cyberleninka:", link)
    text_for_lang = f"{title} {abstract}"
    language = _detect_language(text_for_lang) or "ru"

    return {
        "paper_id": paper_id,
        "link": link,
        "title": title,
        "authors": authors,
        "abstract": abstract,
        "categories": categories,
        "published_date": published or None,
        "updated_date": datestamp or published or None,
        "source": "cyberleninka",
        "language": language,
    }


# ─── CORE API ─────────────────────────────────────────────────────────────────

CORE_BASE = "https://api.core.ac.uk/v3/search/works/"
CORE_DEFAULT_QUERY = (
    "cybersecurity OR malware OR phishing OR ransomware OR vulnerability "
    "OR cryptography OR exploit OR intrusion OR botnet OR firewall"
)


def fetch_core(query: str = "", max_results: int = 50, api_key: Optional[str] = None) -> list[dict]:
    """Fetch papers from CORE API v3. Requires CORE_API_KEY env var or `api_key`."""
    if max_results < 1:
        return []
    token = api_key or os.environ.get("CORE_API_KEY", "").strip()
    if not token:
        raise RuntimeError(
            "CORE_API_KEY is not set. Get a free key at "
            "https://core.ac.uk/services/api and export CORE_API_KEY=..."
        )

    out: list[dict] = []
    offset = 0
    page_size = min(100, max_results)
    q = query or CORE_DEFAULT_QUERY

    with httpx.Client(
        timeout=DEFAULT_TIMEOUT,
        headers={"User-Agent": USER_AGENT, "Authorization": f"Bearer {token}"},
    ) as client:
        while len(out) < max_results:
            limit = min(page_size, max_results - len(out))
            try:
                resp = client.get(
                    CORE_BASE,
                    params={"q": q, "limit": limit, "offset": offset},
                )
                resp.raise_for_status()
            except httpx.HTTPError as exc:
                raise RuntimeError(f"CORE API request failed at offset={offset}: {exc}") from exc

            data = resp.json()
            results = data.get("results") or []
            if not results:
                break

            for item in results:
                row = _parse_core_item(item)
                if row:
                    out.append(row)
                    if len(out) >= max_results:
                        break

            offset += len(results)
            if len(results) < limit:
                break
            time.sleep(1.0)
    return out


def _parse_core_item(item: dict) -> Optional[dict]:
    raw_id = str(item.get("id") or "").strip()
    title = _norm(item.get("title"))
    if not raw_id or not title:
        return None
    abstract = _norm(item.get("abstract"))
    link = _norm(item.get("downloadUrl")) or _norm(item.get("doi"))
    authors_list = item.get("authors") or []
    authors = "; ".join(
        _norm(a.get("name")) for a in authors_list
        if isinstance(a, dict) and a.get("name")
    )
    fields = item.get("fieldOfStudy")
    if isinstance(fields, list):
        categories = "; ".join(_norm(f) for f in fields if f)
    else:
        categories = _norm(fields)
    published = _norm(item.get("publishedDate")) or _norm(item.get("yearPublished"))
    text_for_lang = f"{title} {abstract}"

    return {
        "paper_id": f"core:{raw_id}",
        "link": link,
        "title": title,
        "authors": authors,
        "abstract": abstract,
        "categories": categories,
        "published_date": published or None,
        "updated_date": published or None,
        "source": "core",
        "language": _detect_language(text_for_lang) or "en",
    }


# ─── URL / DOI ───────────────────────────────────────────────────────────────

ARXIV_URL_RE = re.compile(r"arxiv\.org/(?:abs|pdf)/([\w\-./]+?)(?:v\d+)?(?:\.pdf)?$", re.IGNORECASE)
DOI_RE = re.compile(r"^(?:doi:|https?://(?:dx\.)?doi\.org/)(10\.\d{4,9}/\S+)$", re.IGNORECASE)
BARE_DOI_RE = re.compile(r"^10\.\d{4,9}/\S+$")


def fetch_by_url(url: str) -> Optional[dict]:
    """Fetch metadata for a single paper by URL or DOI.

    Supported:
      * arxiv.org/abs/<id>  or  arxiv.org/pdf/<id>      → arXiv Atom API
      * doi.org/<doi>  /  doi:<doi>  /  bare 10.x/y     → Crossref
    """
    if not url:
        return None
    url = url.strip()

    m = ARXIV_URL_RE.search(url)
    if m:
        arxiv_id = re.sub(r"v\d+$", "", m.group(1).rstrip("/"))
        items = fetch_arxiv(query=f"id:{arxiv_id}", max_results=1)
        return items[0] if items else None

    doi = None
    m = DOI_RE.match(url)
    if m:
        doi = m.group(1)
    elif BARE_DOI_RE.match(url):
        doi = url
    if doi:
        return _fetch_crossref_doi(doi)

    raise RuntimeError(
        f"Unsupported URL/DOI: {url!r}. "
        "Supported: arxiv.org/abs/<id>, doi.org/<doi>, or a bare DOI."
    )


def _fetch_crossref_doi(doi: str) -> Optional[dict]:
    url = f"https://api.crossref.org/works/{doi}"
    with httpx.Client(timeout=DEFAULT_TIMEOUT, headers={"User-Agent": USER_AGENT}) as client:
        try:
            resp = client.get(url)
            resp.raise_for_status()
        except httpx.HTTPError as exc:
            raise RuntimeError(f"Crossref request failed for DOI {doi!r}: {exc}") from exc

    msg = (resp.json() or {}).get("message") or {}
    title_list = msg.get("title") or []
    title = _norm(title_list[0]) if title_list else ""
    if not title:
        return None
    abstract = _norm(re.sub(r"<[^>]+>", "", msg.get("abstract") or ""))
    authors = "; ".join(
        _norm(f"{a.get('given', '')} {a.get('family', '')}".strip())
        for a in (msg.get("author") or [])
        if a.get("family") or a.get("given")
    )
    subjects = msg.get("subject") or []
    categories = "; ".join(_norm(s) for s in subjects if s)
    # date parts: prefer published-print, then published-online, then issued
    def _date_from_parts(key: str) -> str:
        node = msg.get(key) or {}
        parts = (node.get("date-parts") or [[]])[0]
        if not parts:
            return ""
        parts = [str(int(p)).zfill(2) for p in parts]
        # year always present at parts[0]
        return "-".join([parts[0]] + parts[1:])

    published = (
        _date_from_parts("published-print")
        or _date_from_parts("published-online")
        or _date_from_parts("issued")
    )
    link = _norm(msg.get("URL")) or f"https://doi.org/{doi}"

    return {
        "paper_id": f"doi:{doi}",
        "link": link,
        "title": title,
        "authors": authors,
        "abstract": abstract,
        "categories": categories,
        "published_date": published or None,
        "updated_date": published or None,
        "source": "doi",
        "language": _detect_language(f"{title} {abstract}") or "en",
    }
