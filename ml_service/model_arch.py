"""
CyberArXiv ML Model Architecture Reference
============================================

The actual model architecture (BertClassifier) is defined in:
  - arxiv_classifier.py  (original training script)
  - app.py               (inline copy for FastAPI service)

Both files define the same BertClassifier class:

    class BertClassifier(nn.Module):
        - Base: distilbert-base-uncased (AutoModel, 768 hidden dim)
        - Head: Dropout -> Linear(768,384) -> GELU -> Dropout -> Linear(384, num_classes)
        - Input: input_ids, attention_mask
        - Output: logits (num_classes)

CHECKPOINT FORMAT (.pt file from training):
    {
        "cfg": {
            "model_name": "distilbert-base-uncased",
            "max_length": 256,
            "batch_size": 32,
            "dropout": 0.3,
            ...
        },
        "label_encoder_classes": [
            "authentication", "blockchain_security", "cryptography",
            "forensics", "hardware_security", "malware", "missing",
            "ml_security", "network_security", "other", "privacy",
            "social_engineering", "vulnerability", "web_security"
        ],
        "model_state": { ... }   # state_dict of BertClassifier
    }

HOW TO USE YOUR EXISTING .pt FILE:
    1. Place your .pt file at:  models/model.pt
    2. The app.py will automatically:
       - Read the config from checkpoint["cfg"]
       - Recreate BertClassifier with matching architecture
       - Load weights from checkpoint["model_state"]
       - Restore label encoder classes from checkpoint["label_encoder_classes"]
    3. Start service: docker-compose up cyberarxiv-ml

NO NEED TO RETRAIN — your existing .pt file works as-is!
"""

# The BertClassifier class is already embedded in app.py.
# This file exists only as documentation.
