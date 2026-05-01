"""File-backed job tracker.

Each job is one JSON file in TRAINING_DATA_DIR/jobs/<job_id>.json.
Survives ml_service restarts so the Shiny UI can poll progress reliably.
"""
from __future__ import annotations

import json
import logging
import threading
import time
import uuid
from dataclasses import dataclass, field, asdict
from typing import Any, Dict, List, Optional

from .paths import jobs_dir

log = logging.getLogger(__name__)

JOB_STATUS = ("pending", "running", "completed", "failed", "cancelled")


@dataclass
class Job:
    id: str
    type: str  # "collect" | "label" | "train" | "export_excel"
    status: str = "pending"
    created_at: float = field(default_factory=time.time)
    updated_at: float = field(default_factory=time.time)
    progress: float = 0.0
    log: List[str] = field(default_factory=list)
    params: Dict[str, Any] = field(default_factory=dict)
    result: Dict[str, Any] = field(default_factory=dict)
    error: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


class JobStore:
    """Thread-safe job persistence. One JSON file per job."""

    def __init__(self) -> None:
        self._lock = threading.Lock()

    def _path(self, job_id: str):
        return jobs_dir() / f"{job_id}.json"

    def create(self, type_: str, params: Dict[str, Any]) -> Job:
        job = Job(id=str(uuid.uuid4()), type=type_, params=params or {})
        self._write(job)
        return job

    def get(self, job_id: str) -> Optional[Job]:
        p = self._path(job_id)
        if not p.exists():
            return None
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
        except Exception as e:
            log.warning("Failed to read job %s: %s", job_id, e)
            return None
        return Job(**data)

    def list(self, type_: Optional[str] = None, limit: int = 100) -> List[Job]:
        d = jobs_dir()
        items = []
        for f in sorted(d.glob("*.json"), key=lambda p: p.stat().st_mtime, reverse=True):
            try:
                data = json.loads(f.read_text(encoding="utf-8"))
                j = Job(**data)
                if type_ and j.type != type_:
                    continue
                items.append(j)
                if len(items) >= limit:
                    break
            except Exception as e:
                log.warning("Skipping unreadable job file %s: %s", f, e)
        return items

    def update(self, job_id: str, **changes) -> Optional[Job]:
        with self._lock:
            job = self.get(job_id)
            if job is None:
                return None
            for k, v in changes.items():
                if hasattr(job, k):
                    setattr(job, k, v)
            job.updated_at = time.time()
            self._write(job)
            return job

    def append_log(self, job_id: str, line: str) -> None:
        with self._lock:
            job = self.get(job_id)
            if job is None:
                return
            job.log.append(line)
            # Cap log to last 2000 lines to keep files bounded.
            if len(job.log) > 2000:
                job.log = job.log[-2000:]
            job.updated_at = time.time()
            self._write(job)

    def delete(self, job_id: str) -> bool:
        p = self._path(job_id)
        if p.exists():
            p.unlink()
            return True
        return False

    def _write(self, job: Job) -> None:
        p = self._path(job.id)
        tmp = p.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(job.to_dict(), ensure_ascii=False, indent=2),
                       encoding="utf-8")
        tmp.replace(p)


_singleton: Optional[JobStore] = None


def get_store() -> JobStore:
    global _singleton
    if _singleton is None:
        _singleton = JobStore()
    return _singleton
