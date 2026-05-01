"""Filesystem layout for training pipeline artifacts.

The base directory is resolved through a cascade:
  1. $TRAINING_DATA_DIR if set and writable (preferred — set by docker-compose)
  2. /srv/cyberarxiv-ml/training_data if writable (default in container)
  3. ./training_data relative to CWD (typical when running locally)
  4. ~/.cyberarxiv/training_data (user home — last resort with guaranteed perms)

We probe by attempting to create the directory and write a small file. The
chosen path is cached on the first call and logged once so it's clear from
the service logs which layout is in effect — this is exactly the kind of
"why is it writing here?" question that wastes hours otherwise.
"""
from __future__ import annotations

import logging
import os
import tempfile
from pathlib import Path
from typing import Optional

log = logging.getLogger(__name__)

_CONTAINER_DEFAULT = "/srv/cyberarxiv-ml/training_data"
_CACHED_BASE: Optional[Path] = None


def _is_writable(p: Path) -> bool:
    try:
        p.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=str(p), delete=True):
            pass
        return True
    except Exception:
        return False


def _resolve_base() -> Path:
    candidates = []
    env = os.environ.get("TRAINING_DATA_DIR")
    if env:
        candidates.append(("env TRAINING_DATA_DIR", Path(env)))
    candidates.append(("container default", Path(_CONTAINER_DEFAULT)))
    candidates.append(("./training_data (CWD)", Path.cwd() / "training_data"))
    candidates.append(("~/.cyberarxiv/training_data",
                       Path.home() / ".cyberarxiv" / "training_data"))
    candidates.append(("temp dir",
                       Path(tempfile.gettempdir()) / "cyberarxiv_training_data"))

    last_err = None
    for source, p in candidates:
        try:
            if _is_writable(p):
                log.info("training_data base dir: %s (source: %s)", p, source)
                return p
        except Exception as e:
            last_err = e
            log.warning("training_data candidate %s (%s) not usable: %s",
                        p, source, e)
    raise RuntimeError(f"No writable training_data dir found. Last error: {last_err}")


def base_dir() -> Path:
    global _CACHED_BASE
    if _CACHED_BASE is None:
        _CACHED_BASE = _resolve_base()
    return _CACHED_BASE


def _sub(name: str) -> Path:
    p = base_dir() / name
    p.mkdir(parents=True, exist_ok=True)
    return p


def raw_dir() -> Path:
    return _sub("raw")


def labeled_dir() -> Path:
    return _sub("labeled")


def excel_dir() -> Path:
    return _sub("excel")


def training_csv_dir() -> Path:
    return _sub("training_csv")


def jobs_dir() -> Path:
    return _sub("jobs")


def config_path() -> Path:
    p = _sub("config")
    return p / "training_config.json"


def models_dir() -> Path:
    """Where finished .pt checkpoints land — read by the inference service."""
    raw = os.environ.get("MODELS_DIR")
    candidates = []
    if raw:
        candidates.append(Path(raw))
    candidates.append(Path("/srv/cyberarxiv-ml/models"))
    candidates.append(Path.cwd() / "models")
    candidates.append(Path.home() / ".cyberarxiv" / "models")

    for p in candidates:
        if _is_writable(p):
            return p
    # Fall through — let the OSError surface from the actual write
    return candidates[0]
