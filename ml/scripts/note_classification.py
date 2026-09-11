"""Turns onset-CNN frame probabilities into discrete note events, and classifies each
as tap or hold based on how long the audio's energy envelope stays elevated after the
onset — the onset CNN only says "a note starts here", not how long it lasts.
"""
from __future__ import annotations

import numpy as np
import librosa


def compute_silence_mask(
    y: np.ndarray, sr: int, hop_length: int, n_frames: int, peak_ratio: float = 0.04,
) -> np.ndarray:
    """Frame-aligned boolean mask, True where the frame is "silent" relative to this
    track's OWN loudness (energy below `peak_ratio` of that track's peak RMS) — a
    track-relative threshold rather than a fixed dB level, since songs/stems vary a
    lot in overall loudness. Used to suppress onset false-positives in near-silent
    stretches (e.g. htdemucs's separation noise floor when an instrument isn't
    actually playing), which otherwise get misread as real note onsets."""
    rms = librosa.feature.rms(y=y, hop_length=hop_length)[0]
    # align frame count to the mel-spectrogram's (librosa's rms and melspectrogram can
    # differ by a frame or two depending on internal padding)
    if len(rms) < n_frames:
        rms = np.pad(rms, (0, n_frames - len(rms)), mode="edge")
    elif len(rms) > n_frames:
        rms = rms[:n_frames]
    threshold = rms.max() * peak_ratio
    return rms < threshold


def pick_peaks(probs: np.ndarray, threshold: float = 0.5, min_separation_frames: int = 3) -> list[int]:
    """Local-maximum peak-picking with non-max suppression: within each contiguous
    run of frames above `threshold`, keep only that run's peak frame; also enforce a
    minimum frame gap between consecutive picked peaks (merges runs that are close
    together but separated by a brief dip)."""
    n = len(probs)
    raw_peaks = []
    i = 0
    while i < n:
        if probs[i] > threshold:
            j = i
            while j < n and probs[j] > threshold:
                j += 1
            raw_peaks.append(i + int(np.argmax(probs[i:j])))
            i = j
        else:
            i += 1

    peaks: list[int] = []
    for p in raw_peaks:
        if peaks and (p - peaks[-1]) < min_separation_frames:
            # too close to the previous pick — keep whichever has higher probability
            if probs[p] > probs[peaks[-1]]:
                peaks[-1] = p
            continue
        peaks.append(p)
    return peaks


def classify_notes(
    y: np.ndarray,
    sr: int,
    onset_times: list[float],
    hop_length: int,
    hold_min_duration: float = 0.2,
    sustain_ratio: float = 0.2,
    frame_length: int = 2048,
) -> list[dict]:
    """For each onset time, measures how long the RMS envelope stays above a
    per-note-relative threshold, and classifies tap vs. hold.

    Threshold is relative to that note's own peak envelope value shortly after onset
    (not a single global level) so quiet notes aren't all misclassified as taps.
    A note ends (for hold-duration purposes) at whichever comes first: the envelope
    dropping below threshold, or the next onset starting.
    """
    rms = librosa.feature.rms(y=y, frame_length=frame_length, hop_length=hop_length)[0]
    n_frames = len(rms)
    frame_rate = sr / hop_length

    # search up to this many frames ahead of an onset to find its local peak envelope
    peak_search_frames = max(1, int(0.05 * frame_rate))  # ~50ms

    notes = []
    for idx, t in enumerate(onset_times):
        onset_frame = int(round(t * frame_rate))
        if onset_frame >= n_frames:
            continue
        next_onset_frame = (
            int(round(onset_times[idx + 1] * frame_rate)) if idx + 1 < len(onset_times) else n_frames
        )

        local_peak = float(np.max(rms[onset_frame: min(n_frames, onset_frame + peak_search_frames)]))
        threshold = local_peak * sustain_ratio

        f = onset_frame
        while f < min(n_frames, next_onset_frame) and rms[f] > threshold:
            f += 1
        sustain_frames = f - onset_frame
        sustain_seconds = sustain_frames / frame_rate

        if sustain_seconds < hold_min_duration:
            notes.append({"time": round(t, 4), "type": "tap", "_intensity": local_peak})
        else:
            end_frame = min(f, next_onset_frame)
            duration = (end_frame - onset_frame) / frame_rate
            notes.append({
                "time": round(t, 4), "type": "hold", "duration": round(duration, 4),
                "_intensity": local_peak,
            })

    return notes


def assign_lanes(
    notes: list[dict],
    lane_count: int = 4,
    simultaneous_ratio: float = 0.175,
    collision_window: float = 0.15,
    rng: np.random.Generator | None = None,
) -> list[dict]:
    """Assigns each note a lane and promotes the strongest onsets to simultaneous
    2-lane notes, so "max 2 simultaneous touches per window" (CLAUDE.md) actually gets
    exercised during play instead of sitting unused.

    - Regular notes: a uniformly random lane, independent of every other note (no
      "must differ from the previous lane" constraint — a repeated lane is a normal,
      allowed outcome, not something to avoid).
    - The top `simultaneous_ratio` fraction of notes by `_intensity` (the local RMS
      peak `classify_notes` already computed for tap/hold classification — reused
      here as an onset-strength proxy) are promoted to 2 simultaneous notes in 2
      different lanes, as long as 2 lanes are free of any other note within
      `collision_window` seconds of this onset. If fewer than 2 lanes are free, the
      promotion is skipped and the note falls back to a single random lane, same as
      any other note.
    - A promoted hold note keeps the same type/duration in both lanes.

    Consumes and strips the internal `_intensity` key — the returned dicts are exactly
    the `{time, type, duration?, lane}` shape written to the final chart JSON.
    """
    if rng is None:
        rng = np.random.default_rng()

    ordered = sorted(notes, key=lambda n: n["time"])
    n_promote = int(round(len(ordered) * simultaneous_ratio))
    promote_ids = set()
    if n_promote > 0:
        by_intensity = sorted(ordered, key=lambda n: n.get("_intensity", 0.0), reverse=True)
        promote_ids = {id(n) for n in by_intensity[:n_promote]}

    placed: list[dict] = []  # finalized {time, lane} entries, for collision lookups
    result: list[dict] = []

    for note in ordered:
        base = {"time": note["time"], "type": note["type"]}
        if "duration" in note:
            base["duration"] = note["duration"]

        nearby_lanes = {p["lane"] for p in placed if abs(p["time"] - note["time"]) <= collision_window}
        free_lanes = [l for l in range(lane_count) if l not in nearby_lanes]

        if id(note) in promote_ids and len(free_lanes) >= 2:
            lanes = rng.choice(free_lanes, size=2, replace=False)
        else:
            lanes = [rng.integers(0, lane_count)]

        for lane in lanes:
            entry = dict(base)
            entry["lane"] = int(lane)
            result.append(entry)
            placed.append({"time": note["time"], "lane": int(lane)})

    result.sort(key=lambda n: n["time"])
    return result
