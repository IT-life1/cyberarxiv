"""
Training script for the CyberArXiv DistilBERT classifier.

This script replicates the training pipeline from main.ipynb
and arxiv_classifier.py, saving checkpoints in the format
that the ML service (app.py) expects:

    {
        "cfg": { "model_name": "distilbert-base-uncased", "max_length": 256, ... },
        "label_encoder_classes": ["authentication", "blockchain_security", ...],
        "model_state": { ... }
    }

DATA REQUIREMENTS:
    --data_dir with:
      - arxiv_classified_dedup.csv  (arxiv_id, primary_category, confidence)
      - arxiv_security_chunks/*.csv (arxiv_id, title, abstract, ...)

Usage:
    python train_model.py --data_dir ./data --output_path ../models/model.pt
    python train_model.py --data_dir ./data --output_path ../models/model.pt --epochs 30 --lr 2e-5

To retrain from scratch:
    python train_model.py --data_dir ./data --output_path ../models/model.pt --freeze_base False
"""

import argparse
import logging
import os

import numpy as np
import torch
import torch.nn as nn
from torch.optim import AdamW
from torch.utils.data import DataLoader
from transformers import get_linear_schedule_with_warmup
from sklearn.metrics import classification_report
from tqdm import tqdm

import pandas as pd

from arxiv_classifier import (
    BertClassifier,
    ArxivDataset,
    build_dataset_df,
    make_dataloaders,
    load_labels,
    load_texts,
)
from sklearn.preprocessing import LabelEncoder

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)


def train_epoch(model, loader, optimizer, scheduler, criterion, device) -> float:
    model.train()
    total_loss = 0.0

    for batch in tqdm(loader, desc="Train", leave=False):
        input_ids = batch["input_ids"].to(device)
        attention_mask = batch["attention_mask"].to(device)
        labels = batch["label"].to(device)

        optimizer.zero_grad()
        logits = model(input_ids, attention_mask)
        loss = criterion(logits, labels)
        loss.backward()

        nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)

        optimizer.step()
        scheduler.step()
        total_loss += loss.item()

    return total_loss / len(loader)


@torch.no_grad()
def eval_epoch(model, loader, criterion, device) -> tuple:
    model.eval()
    total_loss = 0.0
    correct = 0
    total = 0

    for batch in tqdm(loader, desc="Eval", leave=False):
        input_ids = batch["input_ids"].to(device)
        attention_mask = batch["attention_mask"].to(device)
        labels = batch["label"].to(device)

        logits = model(input_ids, attention_mask)
        loss = criterion(logits, labels)
        total_loss += loss.item()

        preds = logits.argmax(dim=-1)
        correct += (preds == labels).sum().item()
        total += labels.size(0)

    return total_loss / len(loader), correct / total


@torch.no_grad()
def predict_all(model, loader, device):
    """Returns (all_preds, all_labels) for final report."""
    model.eval()
    all_preds, all_labels = [], []

    for batch in tqdm(loader, desc="Predict"):
        input_ids = batch["input_ids"].to(device)
        attention_mask = batch["attention_mask"].to(device)

        logits = model(input_ids, attention_mask)
        preds = logits.argmax(dim=-1).cpu().numpy()
        all_preds.extend(preds)
        all_labels.extend(batch["label"].numpy())

    return np.array(all_preds), np.array(all_labels)


def _load_simple_csv(csv_path: str, args) -> tuple:
    """
    Load a user-provided CSV with flexible column names.

    Recognized column names (case-insensitive):
      id column:       id, arxiv_id, paper_id
      text column:     abstract, text, content, body
      label column:    category, label, tag, class, primary_category

    Returns (df, LabelEncoder) ready for make_dataloaders().
    df has columns: text, label (int), primary_category (str)
    """
    log.info(f"Loading simple CSV: {csv_path}")
    raw = pd.read_csv(csv_path)
    log.info(f"  Rows: {len(raw)}, Columns: {list(raw.columns)}")

    col_lower = {c.lower(): c for c in raw.columns}

    def find_col(candidates):
        for c in candidates:
            if c in col_lower:
                return col_lower[c]
        return None

    text_col  = find_col(["abstract", "text", "content", "body"])
    label_col = find_col(["category", "label", "tag", "class", "primary_category"])

    if text_col is None:
        raise ValueError(
            f"No text column found in CSV. Expected one of: abstract, text, content, body. "
            f"Got: {list(raw.columns)}"
        )
    if label_col is None:
        raise ValueError(
            f"No label column found in CSV. Expected one of: category, label, tag, class. "
            f"Got: {list(raw.columns)}"
        )

    log.info(f"  Using text='{text_col}', label='{label_col}'")

    df = raw[[text_col, label_col]].rename(
        columns={text_col: "text", label_col: "primary_category"}
    ).dropna()
    df["text"] = df["text"].astype(str).str.strip()
    df = df[df["text"].str.len() > 10]

    # Filter rare classes
    min_samples = max(2, int(1 / (args.test_size + args.val_size)) + 1)
    counts = df["primary_category"].value_counts()
    rare   = counts[counts < min_samples].index.tolist()
    if rare:
        log.warning(f"Dropping rare classes (< {min_samples} samples): {rare}")
        df = df[~df["primary_category"].isin(rare)]

    le = LabelEncoder()
    df["label"] = le.fit_transform(df["primary_category"])
    log.info(f"  Classes ({len(le.classes_)}): {list(le.classes_)}")
    log.info(f"  Final rows: {len(df)}")
    return df, le


def main():
    parser = argparse.ArgumentParser(description="Train CyberArXiv DistilBERT classifier")

    # Data args — two modes:
    #   --simple_csv  single CSV with id, abstract/text, category/label columns (recommended)
    #   --data_dir    legacy: directory with arxiv_classified_dedup.csv + arxiv_security_chunks/
    parser.add_argument("--simple_csv", type=str, default=None,
                        help=(
                            "Path to a CSV with labelled data. "
                            "Required columns (flexible names): "
                            "id/arxiv_id/paper_id, abstract/text/content, category/label/tag. "
                            "When set, --data_dir is ignored."
                        ))
    parser.add_argument("--data_dir", type=str, default="./data",
                        help="[Legacy] Directory with arxiv_classified_dedup.csv and arxiv_security_chunks/")
    parser.add_argument("--output_path", type=str, default="../models/model.pt",
                        help="Output model checkpoint path")

    # Model args
    parser.add_argument("--model_name", type=str, default="distilbert-base-uncased",
                        help="HuggingFace pretrained model name")
    parser.add_argument("--max_length", type=int, default=256)
    parser.add_argument("--dropout", type=float, default=0.3)
    parser.add_argument("--freeze_base", action="store_true",
                        help="Freeze BERT base weights (only train classifier head)")

    # Training args
    parser.add_argument("--epochs", type=int, default=80)
    parser.add_argument("--batch_size", type=int, default=32)
    parser.add_argument("--lr", type=float, default=2e-5)
    parser.add_argument("--warmup_ratio", type=float, default=0.1)
    parser.add_argument("--weight_decay", type=float, default=0.01)
    parser.add_argument("--patience", type=int, default=15,
                        help="Early stopping patience (epochs without improvement)")

    # Data filtering
    parser.add_argument("--min_confidence", type=float, default=0.0,
                        help="Minimum confidence to include (0.0, 0.5, or 1.0)")
    parser.add_argument("--exclude_other", action="store_true",
                        help="Exclude 'other' category from training")

    # Misc
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--test_size", type=float, default=0.1)
    parser.add_argument("--val_size", type=float, default=0.1)
    args = parser.parse_args()

    torch.manual_seed(args.seed)
    np.random.seed(args.seed)

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    log.info(f"Device: {device}")

    # Build config dict (same format as in arxiv_classifier.py)
    cfg = {
        "data_dir": args.data_dir,
        "labels_csv": "arxiv_classified_dedup.csv",
        "chunks_glob": "arxiv_security_chunks/*.csv",
        "model_name": args.model_name,
        "max_length": args.max_length,
        "batch_size": args.batch_size,
        "num_epochs": args.epochs,
        "lr": args.lr,
        "warmup_ratio": args.warmup_ratio,
        "weight_decay": args.weight_decay,
        "dropout": args.dropout,
        "freeze_base": args.freeze_base,
        "test_size": args.test_size,
        "val_size": args.val_size,
        "min_confidence": args.min_confidence,
        "exclude_other": args.exclude_other,
        "output_dir": os.path.dirname(args.output_path) or ".",
        "seed": args.seed,
    }

    # ---- Build dataset ----
    if args.simple_csv:
        df, le = _load_simple_csv(args.simple_csv, args)
    else:
        df, le = build_dataset_df(cfg)
    num_classes = len(le.classes_)
    log.info(f"Classes ({num_classes}): {list(le.classes_)}")

    # ---- Create tokenizer first (needed by make_dataloaders) ----
    from transformers import AutoTokenizer
    tokenizer = AutoTokenizer.from_pretrained(args.model_name)
    log.info(f"Tokenizer loaded: {args.model_name}")

    # ---- Create dataloaders ----
    train_loader, val_loader, test_loader = make_dataloaders(df, tokenizer, cfg)

    # ---- Build model ----
    log.info(f"Initializing model: {args.model_name}")
    model = BertClassifier(
        model_name=args.model_name,
        num_classes=num_classes,
        dropout=args.dropout,
        freeze_base=args.freeze_base,
    ).to(device)

    trainable_params = sum(p.numel() for p in model.parameters() if p.requires_grad)
    total_params = sum(p.numel() for p in model.parameters())
    log.info(f"Trainable parameters: {trainable_params:,} / {total_params:,}")

    # ---- Optimizer & scheduler ----
    optimizer = AdamW(
        filter(lambda p: p.requires_grad, model.parameters()),
        lr=args.lr,
        weight_decay=args.weight_decay,
    )

    total_steps = len(train_loader) * args.epochs
    warmup_steps = int(total_steps * args.warmup_ratio)
    scheduler = get_linear_schedule_with_warmup(
        optimizer,
        num_warmup_steps=warmup_steps,
        num_training_steps=total_steps,
    )

    criterion = nn.CrossEntropyLoss()

    # ---- Training loop ----
    best_val_acc = 0
    epochs_without_improvement = 0

    for epoch in range(1, args.epochs + 1):
        log.info(f"\n{'=' * 50}")
        log.info(f"Epoch {epoch}/{args.epochs}")

        train_loss = train_epoch(model, train_loader, optimizer, scheduler, criterion, device)
        val_loss, val_acc = eval_epoch(model, val_loader, criterion, device)

        log.info(f"  Train loss: {train_loss:.4f}")
        log.info(f"  Val   loss: {val_loss:.4f}  |  Val acc: {val_acc:.4f}")

        if val_acc > best_val_acc:
            best_val_acc = val_acc
            epochs_without_improvement = 0

            # Save checkpoint in the format expected by app.py
            checkpoint = {
                "cfg": cfg,
                "label_encoder_classes": list(le.classes_),
                "model_state": model.state_dict(),
            }
            os.makedirs(os.path.dirname(args.output_path) or ".", exist_ok=True)
            torch.save(checkpoint, args.output_path)
            log.info(f" Saved best checkpoint (val_acc={val_acc:.4f}) to {args.output_path}")
        else:
            epochs_without_improvement += 1
            log.info(f" No improvement for {epochs_without_improvement} epoch(s)")

        # Early stopping
        if epochs_without_improvement >= args.patience:
            log.info(f"Early stopping: no improvement for {args.patience} epochs")
            break

    # ---- Final evaluation on test set ----
    log.info(f"\n{'=' * 50}")
    log.info("Final evaluation on test set")

    # Load best model
    ckpt = torch.load(args.output_path, map_location=device)
    model.load_state_dict(ckpt["model_state"])
    model.eval()

    test_preds, test_labels = predict_all(model, test_loader, device)
    report = classification_report(test_labels, test_preds, target_names=le.classes_)
    log.info(f"\n{report}")

    log.info(f"Training complete. Best val accuracy: {best_val_acc:.4f}")
    log.info(f"Model saved to: {args.output_path}")

    # ---- MLflow logging (optional) ----
    try:
        import mlflow
        # Honor MLFLOW_TRACKING_URI from env (set by docker-compose / training_pipeline).
        tracking_uri = os.environ.get("MLFLOW_TRACKING_URI")
        if tracking_uri:
            mlflow.set_tracking_uri(tracking_uri)
        experiment = os.environ.get("MLFLOW_EXPERIMENT_NAME", "cyberarxiv-classifier")
        mlflow.set_experiment(experiment)
        with mlflow.start_run():
            mlflow.log_params({
                "model_name": args.model_name,
                "max_length": args.max_length,
                "dropout": args.dropout,
                "freeze_base": args.freeze_base,
                "epochs": args.epochs,
                "batch_size": args.batch_size,
                "learning_rate": args.lr,
                "warmup_ratio": args.warmup_ratio,
                "weight_decay": args.weight_decay,
                "num_classes": num_classes,
                "seed": args.seed,
            })
            mlflow.log_metrics({
                "best_val_accuracy": best_val_acc,
            })
            mlflow.log_artifact(args.output_path)
            log.info("Results logged to MLflow")
    except ImportError:
        log.info("MLflow not installed, skipping logging")
    except Exception as e:
        log.warning(f"MLflow logging failed: {e}")


if __name__ == "__main__":
    main()
