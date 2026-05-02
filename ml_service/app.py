"""
CyberArXiv ML Classification Service
=====================================

Supports multiple models loaded simultaneously from MODELS_DIR.
Each .pt file in the directory becomes a named model (filename without extension).

Example:
  models/general.pt  -> model name "general"
  models/malware.pt  -> model name "malware"

API:
  POST /classify?model=general   (default: first loaded model)
  GET  /models                   (list all loaded models)
  POST /reload_models            (reload all from disk)
"""

import os
import logging
from pathlib import Path

import numpy as np
from contextlib import asynccontextmanager

import torch
import torch.nn as nn
from transformers import AutoTokenizer, AutoModel
from sklearn.preprocessing import LabelEncoder
from fastapi import BackgroundTasks, FastAPI, HTTPException, Query
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from typing import Any, List, Optional, Dict

from training_pipeline import config_store
from training_pipeline import task_registry as tp_tasks
from training_pipeline.job_store import get_store
from training_pipeline.paths import (
    excel_dir,
    labeled_dir,
    raw_dir,
)
from training_pipeline import pipeline as tp_pipeline

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("cyberarxiv-ml")


# ============================================================
# Model Architecture
# ============================================================

class BertClassifier(nn.Module):
    def __init__(self, model_name: str, num_classes: int, dropout: float = 0.3,
                 freeze_base: bool = False):
        super().__init__()
        self.bert = AutoModel.from_pretrained(model_name)

        if freeze_base:
            for param in self.bert.parameters():
                param.requires_grad = False

        hidden_size = self.bert.config.hidden_size
        self.classifier = nn.Sequential(
            nn.Dropout(dropout),
            nn.Linear(hidden_size, hidden_size // 2),
            nn.GELU(),
            nn.Dropout(dropout / 2),
            nn.Linear(hidden_size // 2, num_classes),
        )

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        outputs = self.bert(input_ids=input_ids, attention_mask=attention_mask)
        cls_token = outputs.last_hidden_state[:, 0, :]
        return self.classifier(cls_token)


# ============================================================
# Model store: name -> {model, tokenizer, label_encoder, cfg, info}
# ============================================================

model_store: Dict[str, dict] = {}
device = None


def _load_single_model(name: str, path: str) -> bool:
    """Load one .pt checkpoint into model_store[name]. Returns True on success."""
    global device

    logger.info(f"Loading model '{name}' from {path}")
    try:
        checkpoint = torch.load(path, map_location=device, weights_only=False)
    except Exception as e:
        logger.error(f"Failed to load '{name}': {e}")
        return False

    if not isinstance(checkpoint, dict):
        logger.error(f"Model '{name}': unexpected checkpoint type {type(checkpoint)}")
        return False

    # Config
    cfg = checkpoint.get("cfg", {
        "model_name": "distilbert-base-uncased",
        "max_length": 256,
    })

    # Label encoder
    if "label_encoder_classes" not in checkpoint:
        logger.error(f"Model '{name}': missing 'label_encoder_classes'")
        return False

    le = LabelEncoder()
    le.classes_ = np.array(checkpoint["label_encoder_classes"])

    # Weights
    state_dict = (
        checkpoint.get("model_state")
        or checkpoint.get("model_state_dict")
        or checkpoint.get("state_dict")
    )
    if state_dict is None:
        logger.error(f"Model '{name}': no model weights found in checkpoint")
        return False

    # Build model
    model_name = cfg.get("model_name", "distilbert-base-uncased")
    num_classes = len(le.classes_)
    dropout = cfg.get("dropout", 0.0)

    m = BertClassifier(model_name=model_name, num_classes=num_classes, dropout=dropout)
    try:
        m.load_state_dict(state_dict, strict=True)
    except RuntimeError as e:
        logger.warning(f"Model '{name}': strict load failed ({e}), retrying with strict=False")
        m.load_state_dict(state_dict, strict=False)

    m = m.to(device)
    m.eval()

    tokenizer = AutoTokenizer.from_pretrained(model_name)

    total_params = sum(p.numel() for p in m.parameters())
    info = {
        "path": path,
        "base_model": model_name,
        "num_classes": num_classes,
        "classes": list(le.classes_),
        "max_length": cfg.get("max_length", 256),
        "device": str(device),
        "total_parameters": total_params,
    }

    model_store[name] = {
        "model": m,
        "tokenizer": tokenizer,
        "label_encoder": le,
        "cfg": cfg,
        "info": info,
    }
    logger.info(f"Model '{name}' ready: {num_classes} classes, {total_params:,} params")
    return True


def load_all_models(models_dir: str):
    global device
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    logger.info(f"Device: {device}")

    if not os.path.isdir(models_dir):
        logger.warning(f"Models directory not found: {models_dir}. "
                       "Service will start but /classify will return 503.")
        return

    pt_files = sorted(f for f in os.listdir(models_dir) if f.endswith(".pt"))
    if not pt_files:
        logger.warning(f"No .pt files found in {models_dir}")
        return

    for fname in pt_files:
        name = fname[:-3]
        _load_single_model(name, os.path.join(models_dir, fname))

    logger.info(f"Loaded {len(model_store)} model(s): {list(model_store)}")


def _resolve_model(model_name: Optional[str]) -> str:
    """Return the model key to use, falling back to 'general' then first available."""
    if not model_store:
        raise HTTPException(status_code=503,
                            detail="No models loaded. Place .pt files in MODELS_DIR.")
    if model_name and model_name in model_store:
        return model_name
    if "general" in model_store:
        return "general"
    return next(iter(model_store))


# ============================================================
# Inference
# ============================================================

def predict_single(abstract: str, model_key: str) -> dict:
    entry = model_store[model_key]
    m, tok, le, cfg = entry["model"], entry["tokenizer"], entry["label_encoder"], entry["cfg"]
    max_length = cfg.get("max_length", 256)

    encoding = tok(
        abstract,
        max_length=max_length,
        padding="max_length",
        truncation=True,
        return_tensors="pt",
    )
    input_ids = encoding["input_ids"].to(device)
    attention_mask = encoding["attention_mask"].to(device)

    with torch.no_grad():
        logits = m(input_ids, attention_mask)
        probs = torch.softmax(logits, dim=-1).cpu().numpy()[0]

    pred_idx = int(probs.argmax())
    tag = le.inverse_transform([pred_idx])[0]
    confidence = float(probs[pred_idx])
    all_scores = {cls: round(float(probs[i]), 4) for i, cls in enumerate(le.classes_)}

    return {"tag": tag, "confidence": round(confidence, 4), "all_scores": all_scores}


# ============================================================
# API schemas
# ============================================================

class PaperInput(BaseModel):
    id: str
    abstract: str

class ClassifyRequest(BaseModel):
    papers: List[PaperInput]

class ClassifyResult(BaseModel):
    id: str
    tag: str
    confidence: float
    all_scores: Optional[dict] = None

class ClassifyResponse(BaseModel):
    model_used: str
    results: List[ClassifyResult]


# ============================================================
# App
# ============================================================

@asynccontextmanager
async def lifespan(app):
    models_dir = os.environ.get("MODELS_DIR", "/srv/cyberarxiv-ml/models")
    load_all_models(models_dir)
    yield

app = FastAPI(
    title="CyberArXiv ML Classification Service",
    description="Multi-model classifier. Select model via ?model=<name>.",
    version="2.0.0",
    lifespan=lifespan,
)


@app.get("/health")
async def health_check():
    return {
        "status": "healthy" if model_store else "no_models",
        "models_loaded": len(model_store),
        "models": list(model_store.keys()),
        "device": str(device) if device else "unknown",
    }


@app.get("/models")
async def list_models():
    """List all loaded models and their metadata."""
    return {
        "models": {name: entry["info"] for name, entry in model_store.items()},
        "default": _resolve_model(None) if model_store else None,
    }


@app.post("/classify", response_model=ClassifyResponse)
async def classify_papers(
    request: ClassifyRequest,
    model: Optional[str] = Query(default=None, description="Model name (e.g. 'general', 'malware')"),
):
    """Classify a batch of abstracts. Use ?model= to select the model."""
    model_key = _resolve_model(model)

    results = []
    for paper in request.papers:
        try:
            pred = predict_single(paper.abstract, model_key)
            results.append(ClassifyResult(
                id=paper.id,
                tag=pred["tag"],
                confidence=pred["confidence"],
                all_scores=pred["all_scores"],
            ))
        except Exception as e:
            logger.error(f"Classification failed for paper {paper.id}: {e}")
            results.append(ClassifyResult(id=paper.id, tag="other", confidence=0.0))

    return ClassifyResponse(model_used=model_key, results=results)


@app.post("/classify_single")
async def classify_single(
    paper: PaperInput,
    model: Optional[str] = Query(default=None),
):
    """Classify a single abstract."""
    model_key = _resolve_model(model)
    pred = predict_single(paper.abstract, model_key)
    return {"model_used": model_key, "id": paper.id, **pred}


@app.get("/model_info")
async def model_info(model: Optional[str] = Query(default=None)):
    """Get metadata for a specific model (or default if not specified)."""
    model_key = _resolve_model(model)
    return model_store[model_key]["info"]


@app.post("/reload_models")
async def reload_models():
    """Reload all models from MODELS_DIR."""
    model_store.clear()
    models_dir = os.environ.get("MODELS_DIR", "/srv/cyberarxiv-ml/models")
    load_all_models(models_dir)
    return {
        "status": "reloaded",
        "models": list(model_store.keys()),
    }


# ============================================================
# Training Pipeline API
# ============================================================
#
# These endpoints power the "Обучение" tab in the Shiny GUI:
#   - /training/config        get/update class taxonomy + system prompt + LLM creds
#   - /training/collect       fetch a fresh raw arXiv batch
#   - /training/label         run LLM labelling on a raw parquet
#   - /training/export_excel  produce a reviewable .xlsx from a labeled parquet
#   - /training/train         convert Excel → CSV → run train_model.py → .pt
#   - /training/jobs          poll job state / log
#   - /training/files/...     list & download artifacts under training_data/

class TrainingClass(BaseModel):
    name: str
    description: Optional[str] = ""


class LLMSettings(BaseModel):
    provider: Optional[str] = None
    model: Optional[str] = None
    base_url: Optional[str] = None
    api_key: Optional[str] = None
    temperature: Optional[float] = None
    max_tokens: Optional[int] = None
    request_timeout_secs: Optional[int] = None
    concurrency: Optional[int] = None


class ConfigUpdate(BaseModel):
    classes: Optional[List[TrainingClass]] = None
    system_prompt: Optional[str] = None
    user_prompt_template: Optional[str] = None
    llm: Optional[LLMSettings] = None


class CollectRequest(BaseModel):
    target: int = Field(..., ge=10, le=200_000)
    query: Optional[str] = None
    page_size: int = 200


class LabelRequest(BaseModel):
    raw_path: str
    max_rows: int = 0
    config_overrides: Optional[Dict[str, Any]] = None


class ExportExcelRequest(BaseModel):
    labeled_path: str
    max_rows: int = 0


class TrainRequest(BaseModel):
    excel_path: str
    model_name_out: str = "custom_model"
    base_model: str = "distilbert-base-uncased"
    epochs: int = 8
    batch_size: int = 16
    lr: float = 2e-5
    max_length: int = 256
    test_size: float = 0.1
    val_size: float = 0.1
    mlflow_tracking_uri: Optional[str] = None
    mlflow_experiment: str = "cyberarxiv-classifier"


def _redact(cfg: dict) -> dict:
    """Hide the actual API key in responses. UI shows a stable placeholder
    so users can tell whether one is stored without leaking it back."""
    out = dict(cfg)
    llm = dict(out.get("llm", {}))
    key = llm.get("api_key") or ""
    if key:
        llm["api_key"] = "***" + key[-4:] if len(key) > 4 else "***"
        llm["api_key_set"] = True
    else:
        llm["api_key"] = ""
        llm["api_key_set"] = False
    out["llm"] = llm
    return out


@app.get("/training/health")
async def training_health():
    """Quick check that the training pipeline is wired in properly.

    Verifies: config dir is writable, training_data subdirs exist, and the
    optional LLM SDKs are importable. Use this from the GUI to surface a
    helpful error before the user tries to save anything.
    """
    from training_pipeline.paths import (
        base_dir, config_path, excel_dir, jobs_dir, labeled_dir, raw_dir,
    )
    info: Dict[str, Any] = {
        "ok": True,
        "training_data_dir": str(base_dir()),
        "subdirs": {
            "raw": str(raw_dir()),
            "labeled": str(labeled_dir()),
            "excel": str(excel_dir()),
            "jobs": str(jobs_dir()),
        },
        "config_path": str(config_path()),
        "config_writable": False,
        "sdks": {"openai": False},
        "errors": [],
    }
    try:
        cp = config_path()
        cp.parent.mkdir(parents=True, exist_ok=True)
        probe = cp.parent / ".write_probe"
        probe.write_text("x", encoding="utf-8")
        probe.unlink()
        info["config_writable"] = True
    except Exception as e:
        info["ok"] = False
        info["errors"].append(f"config dir not writable: {e}")
    for sdk in ("openai",):
        try:
            __import__(sdk)
            info["sdks"][sdk] = True
        except Exception as e:
            info["errors"].append(f"sdk {sdk} not importable: {e}")
    return info


@app.get("/training/config")
async def training_get_config():
    try:
        return _redact(config_store.load_config())
    except Exception as e:
        logger.exception("training_get_config failed")
        raise HTTPException(500, f"load_config failed: {e}")


@app.post("/training/config")
async def training_set_config(payload: ConfigUpdate):
    try:
        update: Dict[str, Any] = {}
        if payload.classes is not None:
            update["classes"] = [c.model_dump() for c in payload.classes]
        if payload.system_prompt is not None:
            update["system_prompt"] = payload.system_prompt
        if payload.user_prompt_template is not None:
            update["user_prompt_template"] = payload.user_prompt_template
        if payload.llm is not None:
            # Only include keys that the user explicitly provided. An empty
            # api_key string from the UI means "leave existing key alone"
            # rather than "wipe the key" — we treat None as the wipe signal.
            try:
                llm_payload = payload.llm.model_dump(exclude_unset=True)
            except AttributeError:
                # pydantic v1 fallback
                llm_payload = payload.llm.dict(exclude_unset=True)  # type: ignore[attr-defined]
            if "api_key" in llm_payload and llm_payload["api_key"] == "":
                llm_payload.pop("api_key")
            update["llm"] = llm_payload
        saved = config_store.save_config(update)
        return _redact(saved)
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("training_set_config failed")
        raise HTTPException(500, f"save_config failed: {e}")


@app.post("/training/collect")
async def training_collect(req: CollectRequest, bg: BackgroundTasks):
    store = get_store()
    job = store.create("collect", req.model_dump())
    bg.add_task(tp_pipeline.run_collect_job, job.id)
    return {"job_id": job.id}


@app.post("/training/label")
async def training_label(req: LabelRequest, bg: BackgroundTasks):
    cfg = config_store.load_config()
    if not (cfg.get("llm", {}).get("api_key") or "").strip():
        raise HTTPException(400, "LLM api_key is not configured. POST /training/config first.")
    store = get_store()
    job = store.create("label", req.model_dump())
    bg.add_task(tp_pipeline.run_label_job, job.id)
    return {"job_id": job.id}


@app.post("/training/export_excel")
async def training_export_excel(req: ExportExcelRequest, bg: BackgroundTasks):
    store = get_store()
    job = store.create("export_excel", req.model_dump())
    bg.add_task(tp_pipeline.run_export_excel_job, job.id)
    return {"job_id": job.id}


@app.post("/training/train")
async def training_train(req: TrainRequest, bg: BackgroundTasks):
    if req.mlflow_tracking_uri is None:
        env_uri = os.environ.get("MLFLOW_TRACKING_URI")
        if env_uri:
            req.mlflow_tracking_uri = env_uri
    store = get_store()
    job = store.create("train", req.model_dump())
    bg.add_task(tp_pipeline.run_train_job, job.id)
    return {"job_id": job.id}


@app.get("/training/jobs")
async def training_list_jobs(type: Optional[str] = Query(default=None),
                              limit: int = Query(default=50, ge=1, le=500)):
    store = get_store()
    return [j.to_dict() for j in store.list(type_=type, limit=limit)]


@app.get("/training/jobs/{job_id}")
async def training_get_job(job_id: str):
    store = get_store()
    j = store.get(job_id)
    if j is None:
        raise HTTPException(404, f"Unknown job_id: {job_id}")
    return j.to_dict()


@app.post("/training/jobs/{job_id}/cancel")
async def training_cancel_job(job_id: str):
    store = get_store()
    j = store.get(job_id)
    if j is None:
        raise HTTPException(404, f"Unknown job_id: {job_id}")
    if j.status in ("completed", "failed", "cancelled"):
        return j.to_dict()
    store.update(job_id, status="cancelled")
    return store.get(job_id).to_dict()


@app.delete("/training/jobs/{job_id}")
async def training_delete_job(job_id: str):
    store = get_store()
    ok = store.delete(job_id)
    return {"deleted": ok}


def _safe_subpath(category: str) -> Path:
    if category == "raw":
        return raw_dir()
    if category == "labeled":
        return labeled_dir()
    if category == "excel":
        return excel_dir()
    raise HTTPException(400, "category must be one of: raw, labeled, excel")


def _is_artifact_file(name: str) -> bool:
    """Skip OS junk and editor lock files so the dropdown stays clean.

    LibreOffice creates `.~lock.<name>#` next to opened files; Excel uses
    `~$<name>` for the same purpose; we also skip hidden files and the
    .gitkeep marker.
    """
    if not name or name.startswith("."):
        return False
    if name.startswith("~$"):
        return False
    if name.endswith(".tmp") or name.endswith(".swp"):
        return False
    return True


class RegisterTaskRequest(BaseModel):
    task_name: str
    label: str
    model_name: str
    language: str = "en"


@app.get("/training/tasks")
async def training_list_tasks():
    """Return the user-registered ML-task overrides.

    Built-in tasks live in the R package's inst/ml_tasks.yml — they are
    not visible here. The Shiny app merges both layers itself.
    """
    return tp_tasks.list_tasks()


@app.post("/training/tasks")
async def training_register_task(req: RegisterTaskRequest):
    try:
        return tp_tasks.register_task(
            task_name=req.task_name,
            label=req.label,
            model_name=req.model_name,
            language=req.language,
        )
    except ValueError as e:
        raise HTTPException(400, str(e))
    except Exception as e:
        logger.exception("register_task failed")
        raise HTTPException(500, f"register_task failed: {e}")


@app.delete("/training/tasks/{task_name}")
async def training_delete_task(task_name: str):
    return {"deleted": tp_tasks.delete_task(task_name)}


@app.get("/training/files/{category}")
async def training_list_files(category: str):
    d = _safe_subpath(category)
    items = []
    for f in sorted(d.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True):
        if not f.is_file():
            continue
        if not _is_artifact_file(f.name):
            continue
        items.append({
            "name": f.name,
            "size": f.stat().st_size,
            "mtime": f.stat().st_mtime,
        })
    return items


@app.get("/training/files/{category}/{filename}")
async def training_download_file(category: str, filename: str):
    d = _safe_subpath(category)
    candidate = (d / filename).resolve()
    if d.resolve() not in candidate.parents and candidate != d.resolve():
        raise HTTPException(400, "Path traversal blocked")
    if not candidate.exists():
        raise HTTPException(404, f"File not found: {filename}")
    return FileResponse(str(candidate), filename=filename)


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("ML_SERVICE_PORT", "5001"))
    uvicorn.run(app, host="0.0.0.0", port=port)
