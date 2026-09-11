#!/usr/bin/env python3
"""Build the onset-detection training corpus: for every audio file in every dataset's
manifest, compute a log-mel spectrogram + frame-level onset labels, split into
train/val by FILE (never by frame, to avoid leaking adjacent-frame context across the
split), and cache everything to a single .npz per instrument-source under
ml/output/onset_dataset/.

Usage:
    python build_dataset.py
"""
import json
import random
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from melspec import compute_log_mel, load_audio, onset_times_to_frame_labels
import dataset_loaders as loaders

ML_ROOT = Path(__file__).resolve().parent.parent.parent
DATASETS_ROOT = ML_ROOT / "datasets"
OUTPUT_DIR = ML_ROOT / "output" / "onset_dataset"

VAL_FRACTION = 0.15
RANDOM_SEED = 42


def build_manifest() -> list[dict]:
    manifest = []
    simple_loaders = {
        "guitarset": (loaders.load_guitarset, DATASETS_ROOT / "guitarset"),
        "gmd": (loaders.load_gmd, DATASETS_ROOT / "groove_midi"),
        "babyslakh": (loaders.load_babyslakh, DATASETS_ROOT / "babyslakh" / "babyslakh_16k"),
    }
    for name, (fn, root) in simple_loaders.items():
        if not root.exists():
            print(f"[build_dataset] SKIP {name}: {root} not found (not downloaded yet?)")
            continue
        try:
            items = fn(str(root))
        except Exception as e:
            print(f"[build_dataset] ERROR loading {name}: {e}")
            continue
        print(f"[build_dataset] {name}: {len(items)} files, "
              f"{sum(len(x['onsets']) for x in items)} onsets")
        manifest.extend(items)

    annotated_root = DATASETS_ROOT / "vocalset" / "annotated_vocalset_extracted" / "Annotated VocalSet"
    audio_root = DATASETS_ROOT / "vocalset" / "VocalSet11_extracted"
    if annotated_root.exists() and audio_root.exists():
        try:
            items = loaders.load_vocalset(str(annotated_root), str(audio_root))
            print(f"[build_dataset] vocalset: {len(items)} files, "
                  f"{sum(len(x['onsets']) for x in items)} onsets")
            manifest.extend(items)
        except Exception as e:
            print(f"[build_dataset] ERROR loading vocalset: {e}")
    else:
        print(f"[build_dataset] SKIP vocalset: {annotated_root} or {audio_root} not found")

    return manifest


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    manifest = build_manifest()
    if not manifest:
        print("[build_dataset] no data found, aborting")
        sys.exit(1)

    random.seed(RANDOM_SEED)
    random.shuffle(manifest)
    n_val = max(1, int(len(manifest) * VAL_FRACTION))
    val_files = set(id(x) for x in manifest[:n_val])  # split by file identity

    all_mels = {"train": [], "val": []}
    all_labels = {"train": [], "val": []}
    all_meta = {"train": [], "val": []}
    onset_times_by_split = {"train": [], "val": []}

    for i, item in enumerate(manifest):
        split = "val" if id(item) in val_files else "train"
        try:
            y = load_audio(item["audio_path"])
            log_mel = compute_log_mel(y)
        except Exception as e:
            print(f"[build_dataset] WARN failed to process {item['audio_path']}: {e}")
            continue
        n_frames = log_mel.shape[1]
        labels = onset_times_to_frame_labels(item["onsets"], n_frames)

        all_mels[split].append(log_mel)
        all_labels[split].append(labels)
        all_meta[split].append({
            "audio_path": item["audio_path"], "instrument": item["instrument"],
            "source": item["source"], "n_frames": n_frames, "onsets": item["onsets"],
        })
        onset_times_by_split[split].append((item["instrument"], item["onsets"]))

        if (i + 1) % 50 == 0:
            print(f"[build_dataset] processed {i + 1}/{len(manifest)}")

    def make_ragged_object_array(items):
        # np.array(list_of_2d_arrays, dtype=object) can misinfer a regular (non-ragged)
        # shape when early elements happen to share a frame count, then crash when a
        # later element's shape differs. Assigning element-by-element into a
        # pre-allocated object array always forces ragged storage.
        arr = np.empty(len(items), dtype=object)
        for i, x in enumerate(items):
            arr[i] = x
        return arr

    for split in ("train", "val"):
        out_path = OUTPUT_DIR / f"{split}.npz"
        np.savez(
            out_path,
            mels=make_ragged_object_array(all_mels[split]),
            labels=make_ragged_object_array(all_labels[split]),
        )
        with open(OUTPUT_DIR / f"{split}_meta.json", "w") as f:
            json.dump(all_meta[split], f, indent=2)
        total_frames = sum(m.shape[1] for m in all_mels[split])
        total_onset_frames = sum(int(l.sum()) for l in all_labels[split])
        print(f"[build_dataset] {split}: {len(all_mels[split])} files, "
              f"{total_frames} frames, {total_onset_frames} onset-frames "
              f"({100 * total_onset_frames / max(1, total_frames):.1f}% positive)")

    print(f"[build_dataset] done. Cached to {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
