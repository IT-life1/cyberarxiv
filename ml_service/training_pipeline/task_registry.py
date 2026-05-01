"""ML-task registry: maps a task name to {language: model_name}.

The package-bundled `inst/ml_tasks.yml` (read by R) is read-only after
install. New entries added at runtime go to a user override file inside
TRAINING_DATA_DIR, so they survive package reinstalls and are visible to
the Shiny GUI immediately.
"""
from __future__ import annotations

import logging
import re
from typing import Any, Dict

from .paths import base_dir

log = logging.getLogger(__name__)

_NAME_RE = re.compile(r"^[A-Za-z0-9_]+$")


def override_path():
    p = base_dir() / "config"
    p.mkdir(parents=True, exist_ok=True)
    return p / "ml_tasks_override.yml"


def _load_yaml(path) -> Dict[str, Any]:
    if not path.exists():
        return {}
    try:
        import yaml  # type: ignore
    except ImportError as e:
        raise RuntimeError(
            "PyYAML not installed. `pip install pyyaml`"
        ) from e
    with path.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
    return data if isinstance(data, dict) else {}


def _dump_yaml(path, data: Dict[str, Any]) -> None:
    try:
        import yaml  # type: ignore
    except ImportError as e:
        raise RuntimeError(
            "PyYAML not installed. `pip install pyyaml`"
        ) from e
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)
    tmp.replace(path)


def list_tasks() -> Dict[str, Any]:
    """Return user-defined tasks (override yaml only — built-in tasks live
    in the R package's inst/ml_tasks.yml)."""
    return _load_yaml(override_path())


def register_task(task_name: str, label: str, model_name: str,
                  language: str = "en") -> Dict[str, Any]:
    """Add or overwrite a task entry.

    Validates inputs, writes atomically. Returns the full updated map of
    user-defined tasks (so the caller can confirm what got persisted).
    """
    task_name = (task_name or "").strip()
    label = (label or "").strip()
    model_name = (model_name or "").strip()
    language = (language or "en").strip()

    if not _NAME_RE.match(task_name):
        raise ValueError(
            f"task_name must be snake_case (letters/digits/underscore). Got: '{task_name}'"
        )
    if not label:
        raise ValueError("label must not be empty")
    if not model_name:
        raise ValueError("model_name must not be empty")
    if not _NAME_RE.match(language):
        raise ValueError(f"language must be a short code like 'en'/'ru'. Got: '{language}'")

    path = override_path()
    current = _load_yaml(path)
    current[task_name] = {
        "label": label,
        "models": {language: model_name},
    }
    _dump_yaml(path, current)
    log.info("Registered ML task '%s' → {%s: %s} in %s",
             task_name, language, model_name, path)
    return current


def delete_task(task_name: str) -> bool:
    """Remove a task entry from the override yaml. Returns True if removed."""
    path = override_path()
    current = _load_yaml(path)
    if task_name in current:
        del current[task_name]
        _dump_yaml(path, current)
        return True
    return False
