#!/usr/bin/env python3
"""Visualize CNN onset detections against ground truth on a few sample files per
instrument: waveform + mel-spectrogram with onset markers.

Usage:
    python visualize.py --n-per-instrument 2
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np
import torch
import matplotlib.pyplot as plt

sys.path.insert(0, str(Path(__file__).resolve().parent))
from model import OnsetCNN
from melspec import load_audio, compute_log_mel, SAMPLE_RATE, HOP_LENGTH
from compare_baseline import cnn_predict_onsets

ML_ROOT = Path(__file__).resolve().parent.parent.parent
DATASET_DIR = ML_ROOT / "output" / "onset_dataset"
CHECKPOINT_DIR = ML_ROOT / "output" / "onset_model"
FIG_DIR = ML_ROOT / "output" / "onset_figures"


def plot_file(audio_path: str, ref_onsets, cnn_onsets, instrument: str, out_path: Path):
    y = load_audio(audio_path)
    log_mel = compute_log_mel(y)
    duration = len(y) / SAMPLE_RATE
    times = np.arange(log_mel.shape[1]) * HOP_LENGTH / SAMPLE_RATE

    fig, axes = plt.subplots(2, 1, figsize=(14, 6), sharex=True)

    axes[0].plot(np.linspace(0, duration, len(y)), y, linewidth=0.5, color="steelblue")
    for t in ref_onsets:
        axes[0].axvline(t, color="green", alpha=0.5, linewidth=1)
    axes[0].set_ylabel("waveform")
    axes[0].set_title(f"{instrument}: {Path(audio_path).name}  (green=ground truth onset)")

    axes[1].imshow(log_mel, aspect="auto", origin="lower",
                    extent=[0, duration, 0, log_mel.shape[0]], cmap="magma")
    for t in ref_onsets:
        axes[1].axvline(t, color="green", alpha=0.6, linewidth=1)
    for t in cnn_onsets:
        axes[1].plot(t, log_mel.shape[0] - 2, marker="v", color="red", markersize=6)
    axes[1].set_ylabel("mel bin")
    axes[1].set_xlabel("time (s)")
    axes[1].set_title("log-mel spectrogram (red triangle = CNN-detected onset)")

    fig.tight_layout()
    FIG_DIR.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, dpi=120)
    plt.close(fig)
    print(f"[visualize] wrote {out_path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--n-per-instrument", type=int, default=2)
    args = parser.parse_args()

    with open(DATASET_DIR / "val_meta.json") as f:
        val_meta = json.load(f)

    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    model = OnsetCNN().to(device)
    model.load_state_dict(torch.load(CHECKPOINT_DIR / "onset_cnn_best.pt", map_location=device))
    model.eval()

    by_instrument = {}
    for item in val_meta:
        by_instrument.setdefault(item["instrument"], []).append(item)

    for inst, items in by_instrument.items():
        for item in items[:args.n_per_instrument]:
            y = load_audio(item["audio_path"])
            log_mel = compute_log_mel(y)
            cnn_onsets = cnn_predict_onsets(model, device, log_mel)
            out_path = FIG_DIR / f"{inst}_{Path(item['audio_path']).stem}.png"
            plot_file(item["audio_path"], item["onsets"], cnn_onsets, inst, out_path)


if __name__ == "__main__":
    main()
