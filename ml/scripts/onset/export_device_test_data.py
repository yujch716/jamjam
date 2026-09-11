#!/usr/bin/env python3
"""Export a small batch of real mel-spectrogram windows + the PyTorch model's reference
onset probabilities, for verifying the Core ML model's correctness on real iPad hardware
(not just Mac-side coremltools .predict()).

Usage:
    python scripts/onset/export_device_test_data.py
"""
import sys
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from model import OnsetCNN
from melspec import N_MELS, CONTEXT_FRAMES

ML_ROOT = Path(__file__).resolve().parent.parent.parent
DATASET_DIR = ML_ROOT / "output" / "onset_dataset"
CHECKPOINT_PATH = ML_ROOT / "output" / "onset_model" / "onset_cnn_best.pt"
OUTPUT_DIR = ML_ROOT / "output" / "device_test_data"

N_SAMPLES = 200
BIG_BATCH = 2000  # matches the Mac timing benchmark for apples-to-apples comparison


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    model = OnsetCNN()
    model.load_state_dict(torch.load(CHECKPOINT_PATH, map_location="cpu"))
    model.eval()

    data = np.load(DATASET_DIR / "val.npz", allow_pickle=True)
    mels = data["mels"]

    rng = np.random.default_rng(42)
    windows = np.empty((N_SAMPLES, N_MELS, CONTEXT_FRAMES), dtype=np.float32)
    half = CONTEXT_FRAMES // 2
    for i in range(N_SAMPLES):
        fi = rng.integers(0, len(mels))
        m = mels[fi]
        padded = np.pad(m, ((0, 0), (half, half)), mode="edge")
        t = rng.integers(0, m.shape[1])
        windows[i] = padded[:, t:t + CONTEXT_FRAMES]

    with torch.no_grad():
        ref_probs = torch.sigmoid(model(torch.from_numpy(windows))).numpy().astype(np.float32)

    windows.tofile(OUTPUT_DIR / "test_windows.bin")
    ref_probs.tofile(OUTPUT_DIR / "reference_probs.bin")
    print(f"[export] wrote {N_SAMPLES} windows ({windows.nbytes} bytes) and "
          f"reference probs ({ref_probs.nbytes} bytes) to {OUTPUT_DIR}")
    print(f"[export] windows shape: {windows.shape}, ref_probs shape: {ref_probs.shape}")

    # a bigger synthetic (random) batch just for timing extrapolation on-device,
    # matching the Mac-side benchmark size
    big_batch = rng.standard_normal((BIG_BATCH, N_MELS, CONTEXT_FRAMES)).astype(np.float32)
    big_batch.tofile(OUTPUT_DIR / "timing_batch.bin")
    print(f"[export] wrote timing batch: {big_batch.shape}")


if __name__ == "__main__":
    main()
