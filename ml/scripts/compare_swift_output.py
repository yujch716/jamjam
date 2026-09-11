#!/usr/bin/env python3
"""Compare Swift/Accelerate + Core ML pipeline output (pulled from simulator/device)
against the Python Pre->Core->Post reference (see run_reference.py).

Usage:
    python scripts/compare_swift_output.py --swift-dir <pulled MLPipelineOutput folder>
"""
import argparse
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

ML_ROOT = Path(__file__).resolve().parent.parent
SOURCES = ["drums", "bass", "other", "vocals", "guitar", "piano"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--swift-dir", required=True)
    parser.add_argument("--reference-dir", default=str(ML_ROOT / "output" / "swift_compare" / "python_reference"))
    args = parser.parse_args()

    swift_dir = Path(args.swift_dir)
    ref_dir = Path(args.reference_dir)

    print(f"{'source':<10} {'max abs diff':>14} {'MSE':>12} {'ref peak':>10} {'swift peak':>10} {'verdict'}")
    worst_relative = 0.0
    for name in SOURCES:
        swift_path = swift_dir / f"{name}.wav"
        ref_path = ref_dir / f"{name}.wav"
        if not swift_path.exists():
            print(f"[compare] MISSING: {swift_path}")
            sys.exit(1)
        if not ref_path.exists():
            print(f"[compare] MISSING (run run_reference.py first): {ref_path}")
            sys.exit(1)

        swift_audio, sr1 = sf.read(str(swift_path))
        ref_audio, sr2 = sf.read(str(ref_path))
        assert sr1 == sr2, f"sample rate mismatch: {sr1} vs {sr2}"
        n = min(len(swift_audio), len(ref_audio))
        swift_audio, ref_audio = swift_audio[:n], ref_audio[:n]

        diff = np.abs(swift_audio - ref_audio)
        max_abs = diff.max()
        mse = (diff ** 2).mean()
        ref_peak = np.abs(ref_audio).max()
        swift_peak = np.abs(swift_audio).max()

        relative = max_abs / max(ref_peak, 1e-8)
        worst_relative = max(worst_relative, relative)
        if relative < 0.01:
            verdict = "OK (< 1% of peak)"
        elif relative < 0.05:
            verdict = "marginal (< 5% of peak)"
        else:
            verdict = "LARGE — investigate"

        print(f"{name:<10} {max_abs:>14.3e} {mse:>12.3e} {ref_peak:>10.4f} {swift_peak:>10.4f}  {verdict}")

    print()
    if worst_relative < 0.01:
        print("[compare] RESULT: all stems within 1% of peak amplitude vs. Python reference — "
              "should be perceptually indistinguishable.")
    elif worst_relative < 0.05:
        print("[compare] RESULT: differences are small but noticeable-scale — likely audible "
              "but probably not objectionable; worth a listen.")
    else:
        print("[compare] RESULT: WARNING — some stem(s) diverge significantly from the Python "
              "reference. Check mag_swift.bin vs mag_reference.npy first (isolates STFT); if "
              "that matches, the bug is in ISTFT or the model input/output tensor packing.")
        sys.exit(1)


if __name__ == "__main__":
    main()
