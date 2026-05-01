"""
ArXiv Topic Classifier
======================
Классификация статей по топику на основе abstract.
Модель: DistilBERT + linear classification head.

Структура датасета:
  data_dir/
    arxiv_classified_dedup.csv          <- метки (arxiv_id, primary_category, confidence)
    arxiv_security_chunks/
      arxiv_security_000001_010000.csv  <- тексты (arxiv_id, title, abstract, ...)
      ...
"""

import os
import glob
import logging
from pathlib import Path

import numpy as np
import pandas as pd
import torch
import torch.nn as nn
from torch.utils.data import Dataset, DataLoader
from torch.optim import AdamW
from transformers import AutoTokenizer, AutoModel, get_linear_schedule_with_warmup
from sklearn.preprocessing import LabelEncoder
from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report
from tqdm import tqdm

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)


def load_labels(cfg: dict) -> pd.DataFrame:
    """Загружает файл меток, фильтрует нежелательные классы."""
    path = Path(cfg["data_dir"]) / cfg["labels_csv"]
    log.info(f"Загружаем метки: {path}")
    df = pd.read_csv(path)
    log.info(f"  Строк до фильтрации: {len(df)}")

    if cfg["exclude_other"]:
        df = df[df["primary_category"] != "other"]
        log.info(f"  После исключения 'other': {len(df)}")

    if cfg["min_confidence"] > 0 and "confidence" in df.columns:
        # confidence может быть строкой "high"/"medium"/"low"
        conf_map = {"high": 1.0, "medium": 0.5, "low": 0.0}
        if df["confidence"].dtype == object:
            df = df[df["confidence"].map(conf_map).fillna(0) >= cfg["min_confidence"]]
        else:
            df = df[df["confidence"] >= cfg["min_confidence"]]
        log.info(f"  После фильтра confidence >= {cfg['min_confidence']}: {len(df)}")

    return df[["arxiv_id", "primary_category"]].drop_duplicates("arxiv_id")


def load_texts(cfg: dict) -> pd.DataFrame:
    """
    Загружает все чанки с текстами.
    Использует только arxiv_id + abstract (+ title для обогащения).
    Lazy-loading: читаем по одному файлу, concat в конце.
    """
    pattern = str(Path(cfg["data_dir"]) / cfg["chunks_glob"])
    files = sorted(glob.glob(pattern))
    if not files:
        raise FileNotFoundError(f"Не найдено файлов по паттерну: {pattern}")
    log.info(f"Найдено {len(files)} файлов с текстами")

    chunks = []
    for f in files:
        log.info(f"  Читаем {Path(f).name}...")
        chunk = pd.read_csv(
            f,
            usecols=lambda c: c in {"arxiv_id", "title", "abstract"},
            low_memory=False,
        )
        chunks.append(chunk)

    df = pd.concat(chunks, ignore_index=True)
    log.info(f"Всего текстов: {len(df)}")

    # Убираем дубликаты (одна статья может попасть в несколько чанков)
    df = df.drop_duplicates("arxiv_id")
    log.info(f"После дедупликации: {len(df)}")

    # Удаляем строки без abstract
    df = df.dropna(subset=["abstract"])
    log.info(f"После удаления пустых abstract: {len(df)}")

    return df


def build_dataset_df(cfg: dict) -> tuple[pd.DataFrame, LabelEncoder]:
    """
    Объединяет метки и тексты, кодирует лейблы.
    Возвращает готовый DataFrame и LabelEncoder.
    """
    labels_df = load_labels(cfg)
    texts_df = load_texts(cfg)

    # Merge: берём только статьи, у которых есть и текст, и метка
    df = texts_df.merge(labels_df, on="arxiv_id", how="inner")
    log.info(f"Объединённый датасет: {len(df)} статей")

    # === ДОБАВЛЕННЫЙ БЛОК (ИСПРАВЛЕНИЕ) ===
    # 1. Удаляем NaN в категориях (на случай брака в CSV)
    df = df.dropna(subset=["primary_category"])
    
    # 2. Фильтруем редкие классы (меньше 2 примеров)
    # Stratified split требует минимум 2 примера на класс.
    # Для качественного обучения лучше оставить порог выше (например, >= 5)
    min_samples = 2 
    class_counts = df["primary_category"].value_counts()
    rare_classes = class_counts[class_counts < min_samples].index.tolist()
    
    if rare_classes:
        log.warning(f"Обнаружены редкие классы (< {min_samples} примеров): {rare_classes}")
        log.warning("Эти классы будут удалены из датасета.")
        df = df[~df["primary_category"].isin(rare_classes)]
        log.info(f"Размер датасета после фильтрации: {len(df)}")
    # ======================================

    # Опционально: объединить title + abstract для лучшего контекста
    df["text"] = df["title"].fillna("") + " [SEP] " + df["abstract"]

    # Кодируем метки
    le = LabelEncoder()
    df["label"] = le.fit_transform(df["primary_category"])
    log.info(f"Классы ({len(le.classes_)}): {list(le.classes_)}")

    return df, le

class BertClassifier(nn.Module):
    def __init__(self, model_name: str, num_classes: int, dropout: float = 0.3,
                 freeze_base: bool = False):
        super().__init__()
        self.bert = AutoModel.from_pretrained(model_name)

        if freeze_base:
            for param in self.bert.parameters():
                param.requires_grad = False
            log.info("Базовые веса BERT заморожены")

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
# ─────────────────────────────────────────────
# 2. PYTORCH DATASET
# ─────────────────────────────────────────────

class ArxivDataset(Dataset):
    """
    PyTorch Dataset для классификации текстов.
    Токенизация происходит лениво — в __getitem__.
    """

    def __init__(self, texts: list[str], labels: list[int], tokenizer, max_length: int):
        self.texts = texts
        self.labels = labels
        self.tokenizer = tokenizer
        self.max_length = max_length

    def __len__(self):
        return len(self.texts)

    def __getitem__(self, idx: int) -> dict:
        encoding = self.tokenizer(
            self.texts[idx],
            max_length=self.max_length,
            padding="max_length",
            truncation=True,
            return_tensors="pt",
        )
        return {
            "input_ids": encoding["input_ids"].squeeze(0),        # (max_length,)
            "attention_mask": encoding["attention_mask"].squeeze(0),  # (max_length,)
            "label": torch.tensor(self.labels[idx], dtype=torch.long),
        }


def make_dataloaders(df: pd.DataFrame, tokenizer, cfg: dict) -> tuple:
    """
    Разбивает DataFrame на train/val/test и создаёт DataLoader-ы.
    """
    torch.manual_seed(cfg["seed"])

    train_df, temp_df = train_test_split(
        df, test_size=cfg["test_size"] + cfg["val_size"],
        stratify=df["label"], random_state=cfg["seed"]
    )
    val_df, test_df = train_test_split(
        temp_df, test_size=cfg["test_size"] / (cfg["test_size"] + cfg["val_size"]),
        stratify=temp_df["label"], random_state=cfg["seed"]
    )
    log.info(f"Train: {len(train_df)}, Val: {len(val_df)}, Test: {len(test_df)}")

    def make_loader(sub_df: pd.DataFrame, shuffle: bool) -> DataLoader:
        ds = ArxivDataset(
            texts=sub_df["text"].tolist(),
            labels=sub_df["label"].tolist(),
            tokenizer=tokenizer,
            max_length=cfg["max_length"],
        )
        return DataLoader(
            ds,
            batch_size=cfg["batch_size"],
            shuffle=shuffle,
            num_workers=min(4, os.cpu_count() or 1),
            pin_memory=torch.cuda.is_available(),
        )

    return (
        make_loader(train_df, shuffle=True),
        make_loader(val_df, shuffle=False),
        make_loader(test_df, shuffle=False),
    )


# ─────────────────────────────────────────────
# INFERENCE — использование обученной модели
# ─────────────────────────────────────────────

def load_model_for_inference(checkpoint_path: str, device=None):
    """
    Загружает обученную модель для инференса.

    Пример использования:
        model, tokenizer, le, cfg = load_model_for_inference("checkpoints/best_model.pt")
        label = predict_single(model, tokenizer, le, cfg, "Abstract text here...")
    """
    if device is None:
        device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

    ckpt = torch.load(checkpoint_path, map_location=device)
    cfg = ckpt["cfg"]
    classes = ckpt["label_encoder_classes"]

    le = LabelEncoder()
    le.classes_ = np.array(classes)

    model = BertClassifier(
        model_name=cfg["model_name"],
        num_classes=len(classes),
        dropout=0.0,  # при инференсе dropout отключается через model.eval()
    ).to(device)
    model.load_state_dict(ckpt["model_state"])
    model.eval()

    tokenizer = AutoTokenizer.from_pretrained(cfg["model_name"])
    return model, tokenizer, le, cfg


@torch.no_grad()
def predict_single(model, tokenizer, le, cfg, text: str, device=None) -> str:
    """Предсказывает категорию для одного текста."""
    if device is None:
        device = next(model.parameters()).device

    encoding = tokenizer(
        text,
        max_length=cfg["max_length"],
        padding="max_length",
        truncation=True,
        return_tensors="pt",
    )
    input_ids = encoding["input_ids"].to(device)
    attention_mask = encoding["attention_mask"].to(device)

    logits = model(input_ids, attention_mask)
    probs = torch.softmax(logits, dim=-1).cpu().numpy()[0]
    pred_idx = probs.argmax()

    return le.inverse_transform([pred_idx])[0], float(probs[pred_idx])