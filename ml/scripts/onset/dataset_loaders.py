"""Per-dataset onset manifest builders.

Each loader returns a list of dicts: {"audio_path": str, "onsets": list[float],
"instrument": str, "source": str} — a uniform format the rest of the pipeline
(build_dataset.py) consumes regardless of the underlying dataset's file layout.

Onset definitions per instrument (all "note-start" events, consistent across sources):
  - guitar (GuitarSet): every note_midi onset, any string
  - drums (GMD): every MIDI note-on (drum hit), any drum piece
  - bass (BabySlakh): every MIDI note-on in the bass stem
  - vocals (VocalSet + Annotated-VocalSet): every annotated note onset
"""
from __future__ import annotations

import glob
import os
from pathlib import Path

from midi_utils import onset_times_from_midi


def load_guitarset(root: str) -> list[dict]:
    import jams

    ann_dir = os.path.join(root, "annotation")
    audio_dir = os.path.join(root, "audio_mono-mic")
    audio_files = {Path(p).stem: p for p in glob.glob(os.path.join(audio_dir, "*.wav"))}

    manifest = []
    for jams_path in sorted(glob.glob(os.path.join(ann_dir, "*.jams"))):
        stem = Path(jams_path).stem
        # mirdata/GuitarSet convention: annotation stem + "_mic" suffix for the mono-mic audio
        audio_path = audio_files.get(stem) or audio_files.get(stem + "_mic")
        if audio_path is None:
            # fall back to prefix match
            candidates = [p for s, p in audio_files.items() if s.startswith(stem)]
            audio_path = candidates[0] if candidates else None
        if audio_path is None:
            continue

        j = jams.load(jams_path)
        onsets = []
        for ann in j.search(namespace="note_midi"):
            for obs in ann.data:
                onsets.append(float(obs.time))
        onsets.sort()
        if onsets:
            manifest.append({
                "audio_path": audio_path, "onsets": onsets,
                "instrument": "guitar", "source": "guitarset",
            })
    return manifest


def load_gmd(root: str) -> list[dict]:
    # GMD layout: datasets/groove_midi/groove/<drummer>/<session>/<id>.wav + .mid
    wav_files = glob.glob(os.path.join(root, "**", "*.wav"), recursive=True)
    manifest = []
    for wav_path in sorted(wav_files):
        mid_path = str(Path(wav_path).with_suffix(".mid"))
        if not os.path.exists(mid_path):
            continue
        try:
            onsets = onset_times_from_midi(mid_path)
        except Exception:
            continue
        if onsets:
            manifest.append({
                "audio_path": wav_path, "onsets": onsets,
                "instrument": "drums", "source": "gmd",
            })
    return manifest


def load_babyslakh(root: str) -> list[dict]:
    import yaml

    manifest = []
    for track_dir in sorted(glob.glob(os.path.join(root, "Track*"))):
        meta_path = os.path.join(track_dir, "metadata.yaml")
        if not os.path.exists(meta_path):
            continue
        with open(meta_path) as f:
            meta = yaml.safe_load(f)
        stems_meta = meta.get("stems", {})
        for stem_id, info in stems_meta.items():
            inst_class = (info.get("inst_class") or "").lower()
            if "bass" not in inst_class:
                continue
            wav_path = os.path.join(track_dir, "stems", f"{stem_id}.wav")
            mid_path = os.path.join(track_dir, "MIDI", f"{stem_id}.mid")
            if not (os.path.exists(wav_path) and os.path.exists(mid_path)):
                continue
            try:
                onsets = onset_times_from_midi(mid_path)
            except Exception:
                continue
            if onsets:
                manifest.append({
                    "audio_path": wav_path, "onsets": onsets,
                    "instrument": "bass", "source": "babyslakh",
                })
    return manifest


def _parse_annotated_vocalset_csv(csv_path: str) -> list[float]:
    """Annotated-VocalSet CSV format (inspected directly from the downloaded files):
    6 metadata lines, a blank-ish preamble, then a header row `Sequence, Start time,
    End time, Duration, Type, ...` followed by one row per segment. A segment's
    "Start time" is a note onset only when Type == "Sound" (Type is also "Rest" or
    "Transition" — glide segments between notes, not onsets)."""
    import csv as csv_module

    onsets = []
    with open(csv_path, newline="") as f:
        rows = list(csv_module.reader(f))
    header_idx = next((i for i, r in enumerate(rows) if r and r[0].strip() == "Sequence"), None)
    if header_idx is None:
        return []
    for row in rows[header_idx + 1:]:
        if len(row) < 5:
            continue
        seg_type = row[4].strip()
        if seg_type == "Sound":
            try:
                onsets.append(float(row[1]))
            except ValueError:
                continue
    return sorted(onsets)


def load_vocalset(annotated_root: str, audio_root: str) -> list[dict]:
    """annotated_root: .../vocalset/annotated_vocalset_extracted/Annotated VocalSet
    audio_root: .../vocalset/VocalSet11_extracted (or wherever VocalSet11.zip was extracted)
    Matches each annotation CSV to its audio file by basename stem, searching the
    whole audio tree (VocalSet's own internal nesting doesn't need to be known)."""
    audio_index = {}
    for p in Path(audio_root).rglob("*.wav"):
        audio_index.setdefault(p.stem, str(p))

    manifest = []
    # "extended 1".."extended 4" are 4 redundant annotation passes over the exact same
    # 2688 files (verified: identical filename sets across all four) — use only one
    # pass, otherwise each audio file gets counted up to 4x with near-duplicate labels
    # and could leak across the train/val split (same audio as a "different" file).
    csv_paths = list(Path(annotated_root).glob("extended 1/with file header/*/*.csv"))
    for csv_path in sorted(csv_paths):
        stem = csv_path.stem
        audio_path = audio_index.get(stem)
        if audio_path is None:
            continue
        onsets = _parse_annotated_vocalset_csv(str(csv_path))
        if onsets:
            manifest.append({
                "audio_path": audio_path, "onsets": onsets,
                "instrument": "vocals", "source": "vocalset",
            })
    return manifest
