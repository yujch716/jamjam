#!/usr/bin/env python3
"""Compare the trained CNN against the rule-based spectral-flux baseline on the
validation set, reporting per-instrument and overall F1/precision/recall.

Usage:
    python compare_baseline.py
"""
import json
import sys
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from model import OnsetCNN
from melspec import load_audio, compute_log_mel, extract_windows, FRAME_RATE
from baseline import detect_onsets_spectral_flux
from evaluate import evaluate_corpus

ML_ROOT = Path(__file__).resolve().parent.parent.parent
DATASET_DIR = ML_ROOT / "output" / "onset_dataset"
CHECKPOINT_DIR = ML_ROOT / "output" / "onset_model"


def cnn_predict_onsets(model, device, log_mel: np.ndarray, threshold: float = 0.5) -> np.ndarray:
    n_frames = log_mel.shape[1]
    centers = np.arange(n_frames)
    windows = extract_windows(log_mel, centers)
    x = torch.from_numpy(windows).to(device)
    with torch.no_grad():
        probs = torch.sigmoid(model(x)).cpu().numpy()
    onset_frames = np.where(probs > threshold)[0]
    # merge consecutive onset frames into single onset events (take the first frame
    # of each contiguous run, matching how a real-time peak-picker would fire once)
    if len(onset_frames) == 0:
        return np.array([])
    breaks = np.where(np.diff(onset_frames) > 1)[0]
    starts = np.concatenate(([onset_frames[0]], onset_frames[breaks + 1]))
    return starts / FRAME_RATE


def main():
    with open(DATASET_DIR / "val_meta.json") as f:
        val_meta = json.load(f)

    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    model = OnsetCNN().to(device)
    model.load_state_dict(torch.load(CHECKPOINT_DIR / "onset_cnn_best.pt", map_location=device))
    model.eval()

    by_instrument = {}
    cnn_pairs_all, baseline_pairs_all = [], []

    for item in val_meta:
        y = load_audio(item["audio_path"])
        log_mel = compute_log_mel(y)
        ref = np.array(item["onsets"])

        cnn_est = cnn_predict_onsets(model, device, log_mel)
        baseline_est = detect_onsets_spectral_flux(y)

        inst = item["instrument"]
        by_instrument.setdefault(inst, {"cnn": [], "baseline": []})
        by_instrument[inst]["cnn"].append((ref, cnn_est))
        by_instrument[inst]["baseline"].append((ref, baseline_est))
        cnn_pairs_all.append((ref, cnn_est))
        baseline_pairs_all.append((ref, baseline_est))

    print(f"{'instrument':<10} {'method':<10} {'precision':>10} {'recall':>10} {'F1':>10}")
    for inst, d in sorted(by_instrument.items()):
        for method in ("baseline", "cnn"):
            p, r, f1 = evaluate_corpus(d[method])
            print(f"{inst:<10} {method:<10} {p:>10.3f} {r:>10.3f} {f1:>10.3f}")

    print()
    p, r, f1 = evaluate_corpus(baseline_pairs_all)
    print(f"{'OVERALL':<10} {'baseline':<10} {p:>10.3f} {r:>10.3f} {f1:>10.3f}")
    p, r, f1 = evaluate_corpus(cnn_pairs_all)
    print(f"{'OVERALL':<10} {'cnn':<10} {p:>10.3f} {r:>10.3f} {f1:>10.3f}")


if __name__ == "__main__":
    main()
