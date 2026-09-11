#!/usr/bin/env python3
"""Train the onset-detection CNN on Apple Silicon via PyTorch's MPS backend.

Usage:
    python train.py --epochs 30 --batch-size 256
"""
import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.utils.data import Dataset, DataLoader

sys.path.insert(0, str(Path(__file__).resolve().parent))
from model import OnsetCNN, count_params
from melspec import extract_windows, CONTEXT_HALF, N_MELS, CONTEXT_FRAMES

ML_ROOT = Path(__file__).resolve().parent.parent.parent
DATASET_DIR = ML_ROOT / "output" / "onset_dataset"
CHECKPOINT_DIR = ML_ROOT / "output" / "onset_model"


class WindowedOnsetDataset(Dataset):
    """Every frame of every file is one sample: a CONTEXT_FRAMES-wide mel window
    centered on that frame, labeled with that frame's onset/non-onset target."""

    def __init__(self, npz_path: Path, meta_path: Path | None = None):
        data = np.load(npz_path, allow_pickle=True)
        raw_mels = data["mels"]        # object array of [N_MELS, n_frames] arrays
        self.labels = data["labels"]   # object array of [n_frames] arrays
        # Pre-pad each file's spectrogram ONCE here rather than in __getitem__: padding
        # the full array on every single-frame access would make each file's total
        # __getitem__ cost O(n_frames^2) instead of O(n_frames) — at ~6.8M frames total
        # that turned a few-minutes epoch into an impractically slow one.
        self.mels = [
            np.pad(m, ((0, 0), (CONTEXT_HALF, CONTEXT_HALF)), mode="edge") for m in raw_mels
        ]
        self.instruments = None
        if meta_path is not None and meta_path.exists():
            with open(meta_path) as f:
                meta = json.load(f)
            self.instruments = [m["instrument"] for m in meta]
        # flat index: (file_idx, frame_idx), built with numpy instead of a per-sample
        # Python loop (also O(total frames), but with much lower constant factor)
        file_ids = np.concatenate([np.full(len(lab), fi, dtype=np.int64)
                                    for fi, lab in enumerate(self.labels)])
        frame_ids = np.concatenate([np.arange(len(lab), dtype=np.int64) for lab in self.labels])
        self.index = np.stack([file_ids, frame_ids], axis=1)

    def sample_weights(self) -> np.ndarray:
        """Per-sample weight so each instrument contributes ~equally per epoch,
        regardless of how much raw audio each dataset happened to provide (GMD alone
        has ~13.6h vs. GuitarSet's ~3h, VocalSet's ~10h, BabySlakh's much smaller bass
        slice — without this, the shared model would skew toward drum-like onsets)."""
        assert self.instruments is not None, "meta_path required for balanced sampling"
        instruments = np.array(self.instruments)
        file_instrument = instruments[self.index[:, 0]]
        unique, counts = np.unique(file_instrument, return_counts=True)
        count_map = dict(zip(unique, counts))
        weights = np.array([1.0 / count_map[inst] for inst in file_instrument], dtype=np.float64)
        return weights

    def __len__(self):
        return len(self.index)

    def __getitem__(self, i):
        fi, t = self.index[i]
        window = self.mels[fi][:, t:t + CONTEXT_FRAMES]
        label = self.labels[fi][t]
        return torch.from_numpy(window.copy()), torch.tensor(label, dtype=torch.float32)


def compute_pos_weight(dataset: WindowedOnsetDataset) -> float:
    total = sum(len(l) for l in dataset.labels)
    positives = sum(int(l.sum()) for l in dataset.labels)
    negatives = total - positives
    return negatives / max(1, positives)


def evaluate_loss_and_metrics(model, loader, device, criterion):
    model.eval()
    total_loss = 0.0
    tp = fp = fn = tn = 0
    n = 0
    with torch.no_grad():
        for x, y in loader:
            x, y = x.to(device), y.to(device)
            logits = model(x)
            loss = criterion(logits, y)
            total_loss += loss.item() * x.size(0)
            n += x.size(0)
            preds = (torch.sigmoid(logits) > 0.5).float()
            tp += ((preds == 1) & (y == 1)).sum().item()
            fp += ((preds == 1) & (y == 0)).sum().item()
            fn += ((preds == 0) & (y == 1)).sum().item()
            tn += ((preds == 0) & (y == 0)).sum().item()
    precision = tp / (tp + fp) if (tp + fp) > 0 else 0.0
    recall = tp / (tp + fn) if (tp + fn) > 0 else 0.0
    f1 = 2 * precision * recall / (precision + recall) if (precision + recall) > 0 else 0.0
    return total_loss / max(1, n), precision, recall, f1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--batch-size", type=int, default=256)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--loss", choices=["weighted_bce", "focal"], default="weighted_bce")
    parser.add_argument("--resume", action="store_true",
                         help="resume from onset_cnn_best.pt if present (e.g. after an interrupted run)")
    parser.add_argument("--start-epoch", type=int, default=1,
                         help="epoch number to resume counting from (for correct history/logging)")
    args = parser.parse_args()

    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    print(f"[train] device: {device}")

    train_ds = WindowedOnsetDataset(DATASET_DIR / "train.npz", DATASET_DIR / "train_meta.json")
    val_ds = WindowedOnsetDataset(DATASET_DIR / "val.npz", DATASET_DIR / "val_meta.json")
    print(f"[train] train samples (frames): {len(train_ds)}, val samples: {len(val_ds)}")

    pos_weight = compute_pos_weight(train_ds)
    print(f"[train] class imbalance: pos_weight={pos_weight:.2f} "
          f"(negatives per positive frame)")

    from torch.utils.data import WeightedRandomSampler
    sampler = WeightedRandomSampler(train_ds.sample_weights(), num_samples=len(train_ds), replacement=True)
    train_loader = DataLoader(train_ds, batch_size=args.batch_size, sampler=sampler, num_workers=0)
    val_loader = DataLoader(val_ds, batch_size=args.batch_size, shuffle=False, num_workers=0)

    model = OnsetCNN().to(device)
    print(f"[train] model params: {count_params(model):,}")

    if args.loss == "weighted_bce":
        criterion = nn.BCEWithLogitsLoss(pos_weight=torch.tensor(pos_weight, device=device))
    else:
        # focal loss (Lin et al. 2017), gamma=2, alpha balances toward the rare positive class
        alpha = 1.0 / (1.0 + pos_weight)

        def focal_loss(logits, targets, gamma=2.0):
            bce = nn.functional.binary_cross_entropy_with_logits(logits, targets, reduction="none")
            p = torch.sigmoid(logits)
            p_t = p * targets + (1 - p) * (1 - targets)
            alpha_t = alpha * targets + (1 - alpha) * (1 - targets)
            loss = alpha_t * (1 - p_t) ** gamma * bce
            return loss.mean()

        criterion = focal_loss

    optimizer = torch.optim.Adam(model.parameters(), lr=args.lr)

    CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)
    history = []
    best_f1 = -1.0

    if args.resume:
        ckpt_path = CHECKPOINT_DIR / "onset_cnn_best.pt"
        if ckpt_path.exists():
            model.load_state_dict(torch.load(ckpt_path, map_location=device))
            print(f"[train] resumed weights from {ckpt_path} (optimizer state restarts fresh)")
            history_path = CHECKPOINT_DIR / "training_history.json"
            if history_path.exists():
                with open(history_path) as f:
                    history = json.load(f)
                best_f1 = max((h["val_f1"] for h in history), default=-1.0)
                print(f"[train] loaded {len(history)} prior epoch(s) of history, best_f1={best_f1:.3f}")
        else:
            print(f"[train] --resume given but {ckpt_path} not found, starting fresh")

    last_epoch = args.start_epoch - 1
    for epoch in range(args.start_epoch, args.start_epoch + args.epochs):
        model.train()
        t0 = time.time()
        running_loss = 0.0
        n_seen = 0
        for x, y in train_loader:
            x, y = x.to(device), y.to(device)
            optimizer.zero_grad()
            logits = model(x)
            loss = criterion(logits, y)
            loss.backward()
            optimizer.step()
            running_loss += loss.item() * x.size(0)
            n_seen += x.size(0)

        train_loss = running_loss / n_seen
        val_loss, val_p, val_r, val_f1 = evaluate_loss_and_metrics(model, val_loader, device, criterion)
        elapsed = time.time() - t0
        print(f"[train] epoch {epoch}/{args.start_epoch + args.epochs - 1} train_loss={train_loss:.4f} "
              f"val_loss={val_loss:.4f} val_P={val_p:.3f} val_R={val_r:.3f} val_F1={val_f1:.3f} "
              f"({elapsed:.1f}s)")
        history.append({
            "epoch": epoch, "train_loss": train_loss, "val_loss": val_loss,
            "val_precision": val_p, "val_recall": val_r, "val_f1": val_f1, "seconds": elapsed,
        })
        last_epoch = epoch
        # save history after every epoch (not just at the end) so an interrupted run
        # (e.g. the machine losing power) doesn't lose the training curve
        with open(CHECKPOINT_DIR / "training_history.json", "w") as f:
            json.dump(history, f, indent=2)
        torch.save(model.state_dict(), CHECKPOINT_DIR / "onset_cnn_latest.pt")

        if val_f1 > best_f1:
            best_f1 = val_f1
            torch.save(model.state_dict(), CHECKPOINT_DIR / "onset_cnn_best.pt")
            print(f"[train]   -> new best F1 {val_f1:.3f}, saved checkpoint")

    torch.save(model.state_dict(), CHECKPOINT_DIR / "onset_cnn_final.pt")
    print(f"[train] finished through epoch {last_epoch}")
    print(f"[train] done. best val F1 = {best_f1:.3f}. Checkpoints in {CHECKPOINT_DIR}")


if __name__ == "__main__":
    main()
