"""High-level orchestration glue used by the FastAPI endpoints.

These functions are invoked from BackgroundTasks; each one is responsible
for updating the supplied job through the JobStore as it makes progress.
A failed step writes the error to the job and flips status to 'failed' —
it does not raise into FastAPI's worker thread.
"""
from __future__ import annotations

import logging
import time
import traceback
from datetime import datetime
from pathlib import Path
from typing import Any, Dict

from .config_store import load_config
from .data_collector import collect_arxiv
from .excel_export import excel_to_training_csv, export_to_excel
from .job_store import JobStore, get_store
from .llm_labeler import label_dataframe
from .paths import (
    excel_dir,
    labeled_dir,
    models_dir,
    raw_dir,
    training_csv_dir,
)
from .train_runner import run_training

log = logging.getLogger(__name__)


def _ts() -> str:
    return datetime.now().strftime("%Y%m%d_%H%M%S")


def _logger_for(store: JobStore, job_id: str):
    def log_cb(msg: str):
        store.append_log(job_id, msg)
        log.info("[job %s] %s", job_id, msg)
    return log_cb


def _progress_for(store: JobStore, job_id: str):
    def p(done: int, total: int, message: str = ""):
        pct = 0.0 if total <= 0 else min(1.0, done / total)
        store.update(job_id, progress=pct)
    return p


def _cancel_for(store: JobStore, job_id: str):
    def c() -> bool:
        j = store.get(job_id)
        return j is not None and j.status == "cancelled"
    return c


# ── Step: collect ────────────────────────────────────────────────────────


def run_collect_job(job_id: str) -> None:
    store = get_store()
    job = store.get(job_id)
    if job is None:
        return

    store.update(job_id, status="running", progress=0.0)
    log_cb = _logger_for(store, job_id)
    progress_cb = _progress_for(store, job_id)

    try:
        target = int(job.params.get("target", 1000))
        query = job.params.get("query") or None
        page_size = int(job.params.get("page_size", 200))

        log_cb(f"Collect arXiv: target={target}, page_size={page_size}")
        out_path = raw_dir() / f"arxiv_{_ts()}_{target}.parquet"
        out = collect_arxiv(
            target=target,
            query=query or
                  "(cat:cs.CR OR cat:cs.NI OR cat:cs.LG) AND "
                  "all:(security OR malware OR intrusion OR attack)",
            page_size=page_size,
            output_path=out_path,
            progress_cb=progress_cb,
        )
        log_cb(f"Done. Saved to {out.name}")

        store.update(job_id, status="completed", progress=1.0,
                     result={"file": str(out), "filename": out.name})
    except Exception as e:
        log_cb(f"ERROR: {e}\n{traceback.format_exc()}")
        store.update(job_id, status="failed", error=str(e))


# ── Step: label ──────────────────────────────────────────────────────────


def run_label_job(job_id: str) -> None:
    import pandas as pd

    store = get_store()
    job = store.get(job_id)
    if job is None:
        return

    store.update(job_id, status="running", progress=0.0)
    log_cb = _logger_for(store, job_id)
    progress_cb = _progress_for(store, job_id)
    cancel_cb = _cancel_for(store, job_id)

    try:
        raw_path = Path(job.params["raw_path"])
        if not raw_path.is_absolute():
            raw_path = raw_dir() / raw_path
        if not raw_path.exists():
            raise FileNotFoundError(f"Raw parquet not found: {raw_path}")

        max_rows = int(job.params.get("max_rows", 0) or 0)
        cfg_overrides: Dict[str, Any] = job.params.get("config_overrides") or {}

        cfg = load_config()
        if cfg_overrides:
            for k, v in cfg_overrides.items():
                if k == "llm" and isinstance(v, dict):
                    cfg["llm"] = {**cfg.get("llm", {}), **v}
                else:
                    cfg[k] = v

        df = pd.read_parquet(raw_path)
        log_cb(f"Loaded {len(df)} raw rows from {raw_path.name}")
        if max_rows > 0:
            df = df.head(max_rows)
            log_cb(f"Capped to {len(df)} rows for labeling")

        out_path = labeled_dir() / f"labeled_{_ts()}_{len(df)}.parquet"
        out = label_dataframe(
            df=df,
            cfg=cfg,
            output_path=out_path,
            progress_cb=progress_cb,
            log_cb=log_cb,
            cancel_cb=cancel_cb,
        )

        if cancel_cb():
            store.update(job_id, status="cancelled",
                         result={"file": str(out), "filename": out.name})
            return

        store.update(job_id, status="completed", progress=1.0,
                     result={"file": str(out), "filename": out.name})
    except Exception as e:
        log_cb(f"ERROR: {e}\n{traceback.format_exc()}")
        store.update(job_id, status="failed", error=str(e))


# ── Step: export to excel ────────────────────────────────────────────────


def run_export_excel_job(job_id: str) -> None:
    store = get_store()
    job = store.get(job_id)
    if job is None:
        return

    store.update(job_id, status="running", progress=0.0)
    log_cb = _logger_for(store, job_id)

    try:
        labeled_path = Path(job.params["labeled_path"])
        if not labeled_path.is_absolute():
            labeled_path = labeled_dir() / labeled_path
        if not labeled_path.exists():
            raise FileNotFoundError(f"Labeled parquet not found: {labeled_path}")

        max_rows = int(job.params.get("max_rows", 0) or 0)

        out_name = f"{labeled_path.stem}.xlsx"
        out_path = excel_dir() / out_name
        out = export_to_excel(labeled_parquet=labeled_path,
                               output_path=out_path,
                               max_rows=max_rows or None)
        log_cb(f"Excel ready: {out.name}")

        store.update(job_id, status="completed", progress=1.0,
                     result={"file": str(out), "filename": out.name})
    except Exception as e:
        log_cb(f"ERROR: {e}\n{traceback.format_exc()}")
        store.update(job_id, status="failed", error=str(e))


# ── Step: train ──────────────────────────────────────────────────────────


def run_train_job(job_id: str) -> None:
    import math
    import re

    import pandas as pd

    store = get_store()
    job = store.get(job_id)
    if job is None:
        return

    store.update(job_id, status="running", progress=0.0)
    log_cb_base = _logger_for(store, job_id)
    cancel_cb = _cancel_for(store, job_id)

    # Train_model.py prints `Epoch N/M` and `Final evaluation` lines as it
    # works through training. By regex-matching them we can drive the
    # job.progress bar from outside the subprocess. Phases:
    #   0.00 – 0.05  setup / CSV / pre-flight
    #   0.05 – 0.85  training epochs (linear in epoch number)
    #   0.85 – 0.95  final evaluation
    #   1.00         done
    epoch_re = re.compile(r"^\s*Epoch\s+(\d+)\s*/\s*(\d+)\s*$")

    def log_cb(line: str) -> None:
        log_cb_base(line)
        m = epoch_re.search(line)
        if m:
            cur, total = int(m.group(1)), int(m.group(2))
            if total > 0:
                pct = 0.05 + 0.80 * (cur / total)
                store.update(job_id, progress=min(0.85, pct))
            return
        if "Final evaluation" in line:
            store.update(job_id, progress=0.92)
        elif "Training complete" in line or "Training cancelled." in line:
            store.update(job_id, progress=0.97)

    try:
        excel_path = Path(job.params["excel_path"])
        if not excel_path.is_absolute():
            excel_path = excel_dir() / excel_path
        if not excel_path.exists():
            raise FileNotFoundError(f"Excel not found: {excel_path}")

        model_target_name = job.params.get("model_name_out", f"custom_{_ts()}")
        model_target_name = "".join(
            ch if ch.isalnum() or ch in "_-" else "_" for ch in model_target_name
        )
        if not model_target_name.endswith(".pt"):
            model_target_name += ".pt"

        log_cb(f"Converting {excel_path.name} to training CSV...")
        csv_path = training_csv_dir() / f"{excel_path.stem}.csv"
        excel_to_training_csv(excel_path=excel_path, output_path=csv_path)
        log_cb(f"CSV written: {csv_path.name}")

        # ── Pre-flight check ───────────────────────────────────────────
        # train_model.py drops classes with fewer than 1/(test+val)+1 ≈ 6
        # samples by default. On tiny dev datasets this silently empties
        # the dataset and you get an opaque sklearn error 30 lines later.
        # We compute the same threshold up-front and abort with a
        # human-readable message that tells the user exactly what to do.
        df_pre = pd.read_csv(csv_path)
        test_size = float(job.params.get("test_size", 0.1) or 0.1)
        val_size = float(job.params.get("val_size", 0.1) or 0.1)
        min_per_class = max(2, math.ceil(1.0 / (test_size + val_size)) + 1)

        counts = df_pre["label"].value_counts()
        viable = counts[counts >= min_per_class]
        rare = counts[counts < min_per_class]

        log_cb(f"Dataset summary: rows={len(df_pre)}, "
               f"classes={len(counts)}, "
               f"min_per_class_threshold={min_per_class} "
               f"(derived from test_size+val_size={test_size + val_size:.2f}).")
        if not rare.empty:
            log_cb(
                "Classes with too few samples and that will be dropped: "
                + ", ".join(f"{c}={n}" for c, n in rare.items())
            )

        if len(viable) < 2:
            raise RuntimeError(
                f"Not enough labeled data to train. After applying the "
                f"min_per_class={min_per_class} filter, only {len(viable)} "
                f"class(es) survive — train_test_split needs at least 2. "
                f"Fix it by either: (a) labeling more rows so each class has "
                f">= {min_per_class} examples; (b) lowering test_size and "
                f"val_size in the Training params (e.g. 0.05 each → "
                f"min_per_class drops to 11); or (c) collapsing rare classes "
                f"into 'other' before training. Total labeled rows now: "
                f"{len(df_pre)}, classes seen: {dict(counts)}."
            )
        # ───────────────────────────────────────────────────────────────

        out_path = models_dir() / model_target_name
        log_cb(f"Output checkpoint: {out_path}")

        train_args = {
            "model_name": job.params.get("base_model", "distilbert-base-uncased"),
            "epochs": int(job.params.get("epochs", 8)),
            "batch_size": int(job.params.get("batch_size", 16)),
            "lr": float(job.params.get("lr", 2e-5)),
            "max_length": int(job.params.get("max_length", 256)),
        }
        extra_args = [
            "--test_size", str(test_size),
            "--val_size", str(val_size),
        ]
        store.update(job_id, progress=0.05)

        # Polling progress is hard from outside the subprocess; we surface
        # epoch lines from the log instead. Set progress to 0.5 once we
        # see "Final evaluation".
        rc = run_training(
            csv_path=csv_path,
            output_path=out_path,
            log_cb=log_cb,
            cancel_cb=cancel_cb,
            extra_args=extra_args,
            mlflow_tracking_uri=job.params.get("mlflow_tracking_uri"),
            mlflow_experiment=job.params.get("mlflow_experiment", "cyberarxiv-classifier"),
            **train_args,
        )

        if rc < 0:
            store.update(job_id, status="cancelled", result={"checkpoint": str(out_path)})
            return
        if rc != 0:
            raise RuntimeError(f"train_model.py exited non-zero ({rc})")

        log_cb("Training finished. The new model will be picked up by the "
               "inference service after /reload_models.")
        store.update(
            job_id, status="completed", progress=1.0,
            result={
                "checkpoint": str(out_path),
                "model_name": model_target_name[:-3],
                "csv": str(csv_path),
            },
        )
    except Exception as e:
        log_cb(f"ERROR: {e}\n{traceback.format_exc()}")
        store.update(job_id, status="failed", error=str(e))
