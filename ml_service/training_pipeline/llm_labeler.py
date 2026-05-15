"""LLM-driven dataset labeling.

All providers use the OpenAI-compatible SDK interface. Built-in presets:
  - openai      OpenAI API (default base_url)
  - grok        xAI Grok via https://api.x.ai/v1
  - deepseek    DeepSeek via https://api.deepseek.com/v1
  - other       Any OpenAI-compatible endpoint (user provides base_url)

Labeling contract: the model gets a system prompt + a user prompt assembled
from the user's template, and is expected to return ONLY a category name from
the configured taxonomy. We post-process by lower-casing, trimming, and
matching against the taxonomy. Anything we can't match collapses to "other".

The labeler is deliberately conservative about errors — a single bad LLM call
should not abort an 8-hour 70k-row run.

Environment variables (override config when set):
  - LLM_API_KEY       API key for the LLM provider
  - LLM_MODEL         Model name (e.g. gpt-4o-mini, deepseek-chat)
  - LLM_BASE_URL      Base URL for the API endpoint
  - LLM_PROVIDER      Provider preset (openai, grok, deepseek, other)
"""
from __future__ import annotations

import logging
import os
import re
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Callable, Dict, List, Optional

import pandas as pd

from .config_store import class_names, render_classes_list

log = logging.getLogger(__name__)


class LLMError(Exception):
    pass


# ── Provider clients ──────────────────────────────────────────────────────


class _OpenAIClient:
    """Universal client for all OpenAI-compatible APIs."""

    def __init__(self, api_key: str, model: str, base_url: Optional[str] = None,
                 timeout: int = 60):
        try:
            from openai import OpenAI  # type: ignore
        except ImportError as e:
            raise LLMError(
                "openai SDK not installed. `pip install openai>=1.40.0`"
            ) from e
        kwargs = {"api_key": api_key, "timeout": timeout}
        if base_url:
            kwargs["base_url"] = base_url
        self._client = OpenAI(**kwargs)
        self._model = model

    def complete(self, system: str, user: str, *, temperature: float = 0.0,
                 max_tokens: int = 32) -> str:
        resp = self._client.chat.completions.create(
            model=self._model,
            temperature=temperature,
            max_tokens=max_tokens,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
        )
        choice = resp.choices[0]
        content = choice.message.content or ""
        return content.strip()


def _normalize_base_url(url: str) -> str:
    """Strip endpoint paths users sometimes paste in by mistake.

    The OpenAI/Anthropic SDKs append the endpoint themselves — passing a
    base_url that already contains `/chat/completions` or `/responses`
    yields a 404. We trim those tails so the UI is forgiving.
    """
    if not url:
        return ""
    u = url.strip().rstrip("/")
    for tail in ("/chat/completions", "/completions", "/responses",
                  "/v1/chat/completions", "/v1/responses"):
        if u.endswith(tail):
            u = u[: -len(tail)]
            break
    return u


# Provider → default base_url mapping. Empty string means use SDK default (OpenAI).
PROVIDER_BASE_URLS: Dict[str, str] = {
    "openai": "",
    "grok": "https://api.x.ai/v1",
    "deepseek": "https://api.deepseek.com/v1",
    "other": "",  # user must supply base_url
}


def _build_client(provider: str, api_key: str, model: str, base_url: str,
                  timeout: int):
    provider = (provider or "openai").lower().strip()
    base_url = _normalize_base_url(base_url)

    # If no explicit base_url, use provider default
    if not base_url:
        base_url = PROVIDER_BASE_URLS.get(provider, "")

    return _OpenAIClient(
        api_key=api_key,
        model=model,
        base_url=base_url or None,
        timeout=timeout,
    )


# ── Tag normalisation ─────────────────────────────────────────────────────

_NORM_RE = re.compile(r"[^a-z0-9_]+")


def _normalize(answer: str) -> str:
    a = answer.lower().strip()
    # Take first line — model sometimes adds explanations despite instructions
    a = a.splitlines()[0] if a else ""
    a = a.strip("\"'`. ")
    a = a.replace(" ", "_").replace("-", "_")
    a = _NORM_RE.sub("", a)
    return a


def _match_class(answer: str, allowed: List[str]) -> str:
    if not answer:
        return "other"
    if answer in allowed:
        return answer
    # Fuzzy: substring match
    for c in allowed:
        if c in answer or answer in c:
            return c
    return "other" if "other" in allowed else (allowed[0] if allowed else "other")


# ── Labelling ─────────────────────────────────────────────────────────────


def label_dataframe(
    df: pd.DataFrame,
    cfg: dict,
    output_path: Optional[Path] = None,
    progress_cb: Optional[Callable[[int, int, str], None]] = None,
    log_cb: Optional[Callable[[str], None]] = None,
    cancel_cb: Optional[Callable[[], bool]] = None,
) -> Path:
    """Label every row of `df` and save to a new parquet file.

    Required columns: id, title, abstract.
    Adds: label, llm_raw_answer.
    """
    required = {"id", "title", "abstract"}
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"DataFrame missing columns: {missing}")

    llm_cfg = cfg.get("llm", {})

    # Resolve each LLM field with explicit source tracking. Env vars are an
    # opt-in override for headless runs; if the env value is empty (the
    # default in docker-compose), fall through to the UI-saved config so
    # the user's provider selection actually takes effect.
    def _resolve(env_name: str, cfg_key: str, default):
        env_val = os.environ.get(env_name)
        if env_val:
            return env_val, "env"
        cfg_val = llm_cfg.get(cfg_key)
        if cfg_val:
            return cfg_val, "config"
        return default, "default"

    provider, provider_src = _resolve("LLM_PROVIDER", "provider", "openai")
    model, model_src       = _resolve("LLM_MODEL", "model", "gpt-4o-mini")
    api_key, api_key_src   = _resolve("LLM_API_KEY", "api_key", "")
    base_url, base_url_src = _resolve("LLM_BASE_URL", "base_url", "")

    temperature = float(llm_cfg.get("temperature", 0.0) or 0.0)
    max_tokens = int(llm_cfg.get("max_tokens", 32) or 32)
    timeout = int(llm_cfg.get("request_timeout_secs", 60) or 60)
    concurrency = max(1, int(llm_cfg.get("concurrency", 4) or 4))

    if not api_key:
        raise LLMError(
            "LLM api_key is empty. Set it in the Training tab, "
            "or pass via LLM_API_KEY environment variable."
        )

    classes = class_names(cfg)
    if not classes:
        raise ValueError("No classes configured.")
    classes_list_text = render_classes_list(cfg)

    system_prompt = cfg.get("system_prompt") or ""
    template = cfg.get("user_prompt_template") or ""

    client = _build_client(provider, api_key, model, base_url, timeout)

    if log_cb:
        masked_base = base_url or "(SDK default)"
        log_cb(
            f"LLM: provider={provider} ({provider_src}) "
            f"model={model} ({model_src}) "
            f"base_url={masked_base} ({base_url_src}) "
            f"api_key=({api_key_src}) "
            f"concurrency={concurrency} rows={len(df)}"
        )
        env_overrides = [n for n, s in (
            ("LLM_PROVIDER", provider_src), ("LLM_MODEL", model_src),
            ("LLM_API_KEY", api_key_src), ("LLM_BASE_URL", base_url_src),
        ) if s == "env"]
        if env_overrides:
            log_cb(
                "Note: " + ", ".join(env_overrides) +
                " set in container env — these override the UI config. "
                "Unset them on the host (or remove from docker-compose.yml) "
                "if you want the UI selection to take effect."
            )

    rows: List[dict] = df[["id", "title", "abstract"]].astype(str).to_dict("records")
    results: Dict[int, dict] = {}

    def _format_user(row: dict) -> str:
        return template.format(
            title=row.get("title", ""),
            abstract=row.get("abstract", ""),
            classes_list=classes_list_text,
            classes=", ".join(classes),
        )

    def _worker(idx_row):
        idx, row = idx_row
        user_prompt = _format_user(row)
        last_err = None
        for attempt in range(3):
            try:
                raw = client.complete(system_prompt, user_prompt,
                                       temperature=temperature,
                                       max_tokens=max_tokens)
                normalized = _normalize(raw)
                tag = _match_class(normalized, classes)
                return idx, {"label": tag, "llm_raw_answer": raw,
                             "id": row["id"]}
            except Exception as e:
                last_err = e
                time.sleep(min(8.0, 1.5 ** attempt))
        log.warning("Row %s failed: %s", row.get("id"), last_err)
        return idx, {"label": "other", "llm_raw_answer": f"ERROR: {last_err}",
                     "id": row["id"]}

    done = 0
    total = len(rows)
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = {pool.submit(_worker, (i, r)): i for i, r in enumerate(rows)}
        for f in as_completed(futures):
            if cancel_cb and cancel_cb():
                if log_cb:
                    log_cb("Cancellation requested — stopping.")
                pool.shutdown(wait=False, cancel_futures=True)
                break
            idx, res = f.result()
            results[idx] = res
            done += 1
            if done % 25 == 0 or done == total:
                msg = f"labeled {done}/{total}"
                log.info(msg)
                if log_cb:
                    log_cb(msg)
                if progress_cb:
                    progress_cb(done, total, msg)

    # Stitch results back in row order
    out = df.copy()
    out["label"] = ""
    out["llm_raw_answer"] = ""
    for i, r in results.items():
        out.at[df.index[i], "label"] = r["label"]
        out.at[df.index[i], "llm_raw_answer"] = r["llm_raw_answer"]

    if output_path is None:
        from datetime import datetime
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        output_path = Path(f"labeled_{ts}_{len(out)}.parquet")
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    out.to_parquet(output_path, index=False)

    if log_cb:
        ok = (out["label"] != "other").sum()
        log_cb(f"Saved {len(out)} labeled rows to {output_path.name} "
               f"({ok} matched a class, "
               f"{(out['label'] == 'other').sum()} fell back to 'other')")

    return output_path
