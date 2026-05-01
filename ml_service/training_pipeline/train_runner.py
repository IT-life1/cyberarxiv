"""Run the training script as a background subprocess.

We deliberately spawn `train_model.py` in its own process rather than
importing it: GPU memory tied up by an in-process load would persist
in the FastAPI worker, and a crash in training would take down the
inference service. A subprocess keeps these concerns isolated.

Stdout/stderr are streamed line-by-line into the job log so the Shiny
UI can show training progress in real time.
"""
from __future__ import annotations

import logging
import os
import shlex
import subprocess
import sys
import threading
from pathlib import Path
from typing import Callable, List, Optional

log = logging.getLogger(__name__)


def _train_script_path() -> Path:
    here = Path(__file__).resolve().parent.parent
    return here / "train_model.py"


def run_training(
    csv_path: Path,
    output_path: Path,
    *,
    model_name: str = "distilbert-base-uncased",
    epochs: int = 8,
    batch_size: int = 16,
    lr: float = 2e-5,
    max_length: int = 256,
    extra_args: Optional[List[str]] = None,
    log_cb: Optional[Callable[[str], None]] = None,
    cancel_cb: Optional[Callable[[], bool]] = None,
    mlflow_tracking_uri: Optional[str] = None,
    mlflow_experiment: str = "cyberarxiv-classifier",
) -> int:
    """Launch train_model.py and stream its output. Returns exit code."""
    script = _train_script_path()
    if not script.exists():
        raise FileNotFoundError(f"train_model.py not found at {script}")

    csv_path = Path(csv_path).resolve()
    output_path = Path(output_path).resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    cmd = [
        sys.executable,
        str(script),
        "--simple_csv", str(csv_path),
        "--output_path", str(output_path),
        "--model_name", model_name,
        "--epochs", str(int(epochs)),
        "--batch_size", str(int(batch_size)),
        "--lr", str(float(lr)),
        "--max_length", str(int(max_length)),
    ]
    if extra_args:
        cmd.extend(extra_args)

    env = os.environ.copy()
    if mlflow_tracking_uri:
        env["MLFLOW_TRACKING_URI"] = mlflow_tracking_uri
    env["MLFLOW_EXPERIMENT_NAME"] = mlflow_experiment
    # Stop train_model.py from buffering its output
    env["PYTHONUNBUFFERED"] = "1"

    if log_cb:
        log_cb(f"$ {' '.join(shlex.quote(c) for c in cmd)}")
        log_cb(f"MLFLOW_TRACKING_URI={mlflow_tracking_uri or '(unset)'}")

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
        text=True,
        bufsize=1,
    )

    cancelled = threading.Event()

    def _watch_cancel():
        # Poll for cancellation request and kill if it appears.
        if cancel_cb is None:
            return
        while proc.poll() is None:
            if cancel_cb():
                cancelled.set()
                if log_cb:
                    log_cb("Cancellation requested — terminating training process.")
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                return
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                continue

    watcher = threading.Thread(target=_watch_cancel, daemon=True)
    watcher.start()

    assert proc.stdout is not None
    for raw in proc.stdout:
        line = raw.rstrip()
        if not line:
            continue
        if log_cb:
            log_cb(line)
        else:
            log.info(line)

    rc = proc.wait()
    watcher.join(timeout=2)

    if cancelled.is_set():
        if log_cb:
            log_cb("Training cancelled.")
        return -1

    if log_cb:
        log_cb(f"train_model.py exited with code {rc}")
    return rc
