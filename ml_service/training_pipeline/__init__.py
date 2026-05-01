"""
CyberArXiv Training Pipeline
============================
End-to-end pipeline for training custom DistilBERT classifiers:
  1. Collect raw papers from arXiv
  2. Label them with an LLM (OpenAI / Anthropic / xAI Grok)
  3. Export the labeled dataset to Excel for review
  4. Run training (reuses train_model.py) and produce a .pt checkpoint
  5. Hot-reload the new model into the inference service

Job state and intermediate artifacts live under TRAINING_DATA_DIR
(default: /srv/cyberarxiv-ml/training_data inside the container,
./training_data on the host).
"""

from .config_store import (
    DEFAULT_CONFIG,
    load_config,
    save_config,
)
from .job_store import JOB_STATUS, Job, JobStore
from .data_collector import collect_arxiv
from .task_registry import register_task

__all__ = [
    "DEFAULT_CONFIG",
    "load_config",
    "save_config",
    "JOB_STATUS",
    "Job",
    "JobStore",
    "collect_arxiv",
    "register_task",
]
