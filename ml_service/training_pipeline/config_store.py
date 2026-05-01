"""Persistent configuration: classes, system prompt, LLM provider settings."""
from __future__ import annotations

import json
import logging
from typing import Any, Dict

from .paths import config_path

log = logging.getLogger(__name__)


DEFAULT_SYSTEM_PROMPT = (
    "You are an expert cybersecurity research librarian. "
    "Your job is to read the title and abstract of a paper and assign exactly one "
    "category from a fixed taxonomy provided by the user. "
    "Respond with ONLY the category name in snake_case, no extra words, "
    "no quotes, no punctuation. If none of the categories fits, answer 'other'."
)

DEFAULT_USER_TEMPLATE = (
    "Title: {title}\n\n"
    "Abstract: {abstract}\n\n"
    "Pick exactly one category from this list:\n{classes_list}\n\n"
    "Reply with just the category name."
)

DEFAULT_CLASSES = [
    {"name": "malware", "description": "Виды и анализ зловредного ПО (трояны, ботнеты, ransomware)."},
    {"name": "phishing", "description": "Фишинг, социальная инженерия, мошенничество."},
    {"name": "intrusion_detection", "description": "IDS/IPS, обнаружение вторжений, анализ сетевого трафика."},
    {"name": "cryptography", "description": "Криптография, шифрование, протоколы, hash-функции."},
    {"name": "vulnerability_analysis", "description": "Поиск и анализ уязвимостей, fuzzing, эксплойты."},
    {"name": "authentication", "description": "Аутентификация, MFA, биометрия, управление идентификацией."},
    {"name": "privacy", "description": "Приватность, дифференциальная приватность, анонимизация."},
    {"name": "blockchain_security", "description": "Безопасность блокчейна и смарт-контрактов."},
    {"name": "iot_security", "description": "IoT, embedded, киберфизические системы."},
    {"name": "ml_security", "description": "Adversarial ML, безопасность моделей, отравление данных."},
    {"name": "other", "description": "Не подходит ни под одну из категорий выше."},
]

DEFAULT_LLM = {
    "provider": "openai",
    "model": "gpt-4o-mini",
    "base_url": "",
    "api_key": "",
    "temperature": 0.0,
    "max_tokens": 32,
    "request_timeout_secs": 60,
    "concurrency": 4,
}

DEFAULT_CONFIG: Dict[str, Any] = {
    "classes": DEFAULT_CLASSES,
    "system_prompt": DEFAULT_SYSTEM_PROMPT,
    "user_prompt_template": DEFAULT_USER_TEMPLATE,
    "llm": DEFAULT_LLM,
}


def _atomic_write(path, payload: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    try:
        tmp.write_text(payload, encoding="utf-8")
        tmp.replace(path)
    except OSError as e:
        raise OSError(
            f"Failed to write training config to {path}: {e}. "
            f"Hint: ensure the directory is writable, or set TRAINING_DATA_DIR "
            f"to a path you own (e.g. ./training_data when running outside Docker)."
        ) from e


def load_config() -> Dict[str, Any]:
    """Read config from disk, filling in defaults for any missing keys."""
    p = config_path()
    if not p.exists():
        return json.loads(json.dumps(DEFAULT_CONFIG))  # deep-copy

    try:
        raw = json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:
        log.warning("Failed to read training config (%s); falling back to defaults", e)
        return json.loads(json.dumps(DEFAULT_CONFIG))

    merged = json.loads(json.dumps(DEFAULT_CONFIG))
    if isinstance(raw, dict):
        for k, v in raw.items():
            if k == "llm" and isinstance(v, dict):
                merged["llm"] = {**merged["llm"], **v}
            else:
                merged[k] = v
    return merged


def save_config(cfg: Dict[str, Any]) -> Dict[str, Any]:
    """Persist config (merged with current state to allow partial updates)."""
    current = load_config()

    if "classes" in cfg:
        current["classes"] = _normalize_classes(cfg["classes"])
    if "system_prompt" in cfg and isinstance(cfg["system_prompt"], str):
        current["system_prompt"] = cfg["system_prompt"]
    if "user_prompt_template" in cfg and isinstance(cfg["user_prompt_template"], str):
        current["user_prompt_template"] = cfg["user_prompt_template"]
    if "llm" in cfg and isinstance(cfg["llm"], dict):
        current["llm"] = {**current["llm"], **cfg["llm"]}

    _atomic_write(config_path(), json.dumps(current, ensure_ascii=False, indent=2))
    return current


def _normalize_classes(classes) -> list:
    if not isinstance(classes, list):
        return DEFAULT_CLASSES
    out = []
    seen = set()
    for c in classes:
        if isinstance(c, str):
            name = c.strip()
            desc = ""
        elif isinstance(c, dict):
            name = str(c.get("name", "")).strip()
            desc = str(c.get("description", "")).strip()
        else:
            continue
        if not name or name in seen:
            continue
        seen.add(name)
        out.append({"name": name, "description": desc})
    return out or DEFAULT_CLASSES


def class_names(cfg: Dict[str, Any]) -> list:
    return [c["name"] for c in cfg.get("classes", []) if isinstance(c, dict) and c.get("name")]


def render_classes_list(cfg: Dict[str, Any]) -> str:
    """Pretty list inserted into the user prompt template."""
    items = []
    for c in cfg.get("classes", []):
        nm = c.get("name", "").strip()
        ds = c.get("description", "").strip()
        if not nm:
            continue
        if ds:
            items.append(f"- {nm}: {ds}")
        else:
            items.append(f"- {nm}")
    return "\n".join(items)
