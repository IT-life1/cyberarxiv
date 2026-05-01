"""Excel ↔ DataFrame helpers.

Two operations:
  - export_to_excel(): take a labeled parquet → write .xlsx for human review
  - excel_to_training_csv(): take a (possibly user-edited) .xlsx → write the
    simple CSV that train_model.py consumes via its --simple_csv flag.

We keep the Excel sheet intentionally minimal (id, title, abstract, label,
llm_raw_answer). Reviewers can correct labels directly in the file.
"""
from __future__ import annotations

import logging
from pathlib import Path
from typing import Optional

import pandas as pd

log = logging.getLogger(__name__)

EXCEL_COLUMNS = ["id", "title", "abstract", "label", "llm_raw_answer"]


def export_to_excel(
    labeled_parquet: Path,
    output_path: Optional[Path] = None,
    max_rows: Optional[int] = None,
) -> Path:
    """Write a clean .xlsx from a labeled parquet.

    `max_rows` is a defensive cap — Excel itself caps at ~1,048,576 rows per
    sheet. For very large jobs (70k rows is fine) we still write a single
    sheet, but if the dataset is huge we split into sheet1, sheet2, ... by
    chunks of 1,000,000.
    """
    df = pd.read_parquet(labeled_parquet)
    for col in EXCEL_COLUMNS:
        if col not in df.columns:
            df[col] = ""
    df = df[EXCEL_COLUMNS]

    if max_rows is not None and max_rows > 0:
        df = df.head(int(max_rows))

    if output_path is None:
        output_path = Path(labeled_parquet).with_suffix(".xlsx")
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    excel_max = 1_000_000  # leave a margin under 1,048,576
    try:
        if len(df) <= excel_max:
            df.to_excel(output_path, index=False, engine="openpyxl")
        else:
            with pd.ExcelWriter(output_path, engine="openpyxl") as xl:
                for i, start in enumerate(range(0, len(df), excel_max)):
                    chunk = df.iloc[start:start + excel_max]
                    chunk.to_excel(xl, index=False, sheet_name=f"sheet{i+1}")
    except ImportError as e:
        raise RuntimeError(
            "openpyxl not installed. `pip install openpyxl`"
        ) from e

    log.info("Excel written: %s (%d rows)", output_path, len(df))
    return output_path


def excel_to_training_csv(
    excel_path: Path,
    output_path: Optional[Path] = None,
) -> Path:
    """Convert reviewed .xlsx back into a CSV consumable by train_model.py.

    train_model.py expects columns: id, abstract, label (any of these names work).
    We pass through abstract + label, plus id for traceability.
    Rows with empty / missing label are dropped.
    """
    excel_path = Path(excel_path)
    name = excel_path.name
    if name.startswith(".~lock") or name.startswith("~$"):
        raise ValueError(
            f"'{name}' looks like an editor lock file, not a real spreadsheet. "
            f"Close the file in LibreOffice/Excel and select the actual .xlsx."
        )
    df = pd.read_excel(excel_path, engine="openpyxl")

    rename = {}
    cols_lower = {c.lower(): c for c in df.columns}
    for want, alts in [
        ("id", ["id", "arxiv_id", "paper_id"]),
        ("abstract", ["abstract", "text", "content", "body"]),
        ("label", ["label", "category", "tag", "class", "primary_category"]),
        ("title", ["title"]),
    ]:
        for a in alts:
            if a in cols_lower:
                rename[cols_lower[a]] = want
                break

    df = df.rename(columns=rename)
    if "abstract" not in df.columns or "label" not in df.columns:
        raise ValueError(
            f"Excel missing required columns. Need at least: abstract + label. "
            f"Got: {list(df.columns)}"
        )

    keep = ["id", "title", "abstract", "label"]
    keep = [c for c in keep if c in df.columns]
    df = df[keep]

    df["label"] = df["label"].astype(str).str.strip()
    df["abstract"] = df["abstract"].astype(str).str.strip()
    df = df[(df["label"] != "") & (df["label"].str.lower() != "nan")]
    df = df[df["abstract"].str.len() > 10]

    if output_path is None:
        output_path = excel_path.with_suffix(".csv")
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(output_path, index=False, encoding="utf-8")

    log.info("Training CSV written: %s (%d rows, %d classes)",
             output_path, len(df), df["label"].nunique())
    return output_path
