#!/usr/bin/env python3
"""End-to-end integration test (Python side, before porting to Swift/Core ML):
mp3 in -> demucs 6-source separation -> per-instrument onset CNN -> peak-picking ->
tap/hold classification -> note_chart JSON, for the 4 instruments the game actually
uses (guitar/drums/bass/piano — piano reuses the guitar/drums/bass/vocals-trained
onset model as a generalization test, no dedicated piano data).

Outputs, per instrument, under ml/output/full_pipeline/<song_name>/:
  - <instrument>_chart.json   the note_chart itself ({time, type, duration?}[])
  - <instrument>.wav          the separated stem audio (44.1kHz)
  - <instrument>_click.wav    stem audio + a short click at every note onset
  - <instrument>_viz.png      waveform + log-mel spectrogram with note markers

Usage:
    python scripts/full_pipeline.py --input test-assets/song.mp3
"""
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
import torch.nn.functional as F
import matplotlib.pyplot as plt

ML_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ML_ROOT / "scripts"))
sys.path.insert(0, str(ML_ROOT / "scripts" / "onset"))

import htdemucs_split as split  # noqa: E402
from note_classification import pick_peaks, classify_notes, compute_silence_mask, assign_lanes  # noqa: E402
from model import OnsetCNN  # noqa: E402
import melspec as onset_melspec  # noqa: E402

GAME_INSTRUMENTS = {
    "guitar": "guitar",
    "drums": "drums",
    "bass": "bass",
    "piano": "piano",  # no dedicated training data — reuses the shared onset model
}
ONSET_THRESHOLD = 0.5
PEAK_MIN_SEPARATION_SECONDS = 0.05
HOLD_MIN_DURATION = 0.2
SUSTAIN_RATIO = 0.2
SILENCE_PEAK_RATIO = 0.04  # frames below 4% of a track's own peak RMS are never onsets
LANE_COUNT = 4
SIMULTANEOUS_RATIO = 0.175  # top ~17.5% of onsets by intensity become 2-lane notes
COLLISION_WINDOW_SECONDS = 0.15
LANE_SEED = 42  # fixed for this test script so re-runs are directly comparable

ONSET_CHECKPOINT = ML_ROOT / "output" / "onset_model" / "onset_cnn_best.pt"
OUTPUT_ROOT = ML_ROOT / "output" / "full_pipeline"


def ensure_wav(input_path: Path) -> Path:
    if input_path.suffix.lower() == ".wav":
        return input_path
    out_path = input_path.with_suffix(".decoded.wav")
    if not out_path.exists():
        print(f"[pipeline] decoding {input_path.name} -> {out_path.name} via afconvert")
        subprocess.run(
            ["afconvert", "-d", "LEF32@44100", "-f", "WAVE", "-c", "2", str(input_path), str(out_path)],
            check=True,
        )
    return out_path


def separate_full_song(model, core, mix: torch.Tensor) -> torch.Tensor:
    """Chunked Pre->Core->Post separation with 50%-overlap Hann-window crossfade,
    matching what the Swift/Core ML port will eventually have to do for full songs
    (the Core ML model only accepts exactly one training-length segment at a time)."""
    training_length = int(model.segment * model.samplerate)
    hop = training_length // 2
    L = mix.shape[-1]

    pad = hop
    mix_padded = F.pad(mix, (pad, pad))
    Lp = mix_padded.shape[-1]
    n_chunks = max(1, int(np.ceil(max(0, Lp - training_length) / hop)) + 1)
    out_len = (n_chunks - 1) * hop + training_length

    S = len(model.sources)
    C = model.audio_channels
    output = torch.zeros(1, S, C, out_len)
    window = torch.hann_window(training_length)  # COLA at 50% hop -> unity-gain OLA

    print(f"[separate] {n_chunks} chunks of {training_length / model.samplerate:.2f}s "
          f"(50% overlap) for a {L / model.samplerate:.1f}s song")
    t0 = time.time()
    for i in range(n_chunks):
        start = i * hop
        chunk = mix_padded[..., start:start + training_length]
        if chunk.shape[-1] < training_length:
            chunk = F.pad(chunk, (0, training_length - chunk.shape[-1]))
        with torch.no_grad():
            sep = split.split_forward(model, core, chunk)  # [1, S, C, training_length]
        output[..., start:start + training_length] += sep * window.view(1, 1, 1, -1)
        if (i + 1) % 10 == 0 or i == n_chunks - 1:
            print(f"[separate] chunk {i + 1}/{n_chunks} ({time.time() - t0:.1f}s elapsed)")

    return output[..., pad:pad + L]  # [1, S, C, L]


def detect_notes(onset_model: OnsetCNN, y_stereo: np.ndarray, sr: int) -> list[dict]:
    """y_stereo: [C, L] at sr Hz -> mono at the onset model's sample rate -> log-mel ->
    per-frame onset probability -> peaks -> tap/hold-classified notes."""
    import librosa

    y_mono = y_stereo.mean(axis=0)
    if sr != onset_melspec.SAMPLE_RATE:
        y_mono_model_sr = librosa.resample(y_mono, orig_sr=sr, target_sr=onset_melspec.SAMPLE_RATE)
    else:
        y_mono_model_sr = y_mono

    log_mel = onset_melspec.compute_log_mel(y_mono_model_sr)
    n_frames = log_mel.shape[1]
    windows = onset_melspec.extract_windows(log_mel, np.arange(n_frames))
    with torch.no_grad():
        probs = torch.sigmoid(onset_model(torch.from_numpy(windows))).numpy()

    # energy pre-filter: never treat a near-silent frame as an onset candidate,
    # regardless of what the CNN thinks — guards against separation-noise false
    # positives (htdemucs's piano stem in particular, but applied uniformly to all
    # instruments as a general safety net, not a piano-specific special case)
    silence_mask = compute_silence_mask(
        y_mono_model_sr, onset_melspec.SAMPLE_RATE,
        hop_length=onset_melspec.HOP_LENGTH, n_frames=n_frames, peak_ratio=SILENCE_PEAK_RATIO,
    )
    probs_filtered = probs.copy()
    probs_filtered[silence_mask] = 0.0

    min_sep_frames = max(1, int(PEAK_MIN_SEPARATION_SECONDS * onset_melspec.FRAME_RATE))
    peak_frames = pick_peaks(probs_filtered, threshold=ONSET_THRESHOLD, min_separation_frames=min_sep_frames)
    onset_times = [f / onset_melspec.FRAME_RATE for f in peak_frames]

    notes = classify_notes(
        y_mono, sr, onset_times,
        hop_length=int(sr / onset_melspec.FRAME_RATE),
        hold_min_duration=HOLD_MIN_DURATION, sustain_ratio=SUSTAIN_RATIO,
    )
    n_onsets = len(notes)
    notes = assign_lanes(
        notes, lane_count=LANE_COUNT, simultaneous_ratio=SIMULTANEOUS_RATIO,
        collision_window=COLLISION_WINDOW_SECONDS, rng=np.random.default_rng(LANE_SEED),
    )
    return notes, log_mel, probs, n_onsets


def make_click_track(y_stereo: np.ndarray, sr: int, notes: list[dict]) -> np.ndarray:
    click_len = int(0.03 * sr)
    t = np.arange(click_len) / sr
    click = np.sin(2 * np.pi * 1200 * t) * np.exp(-t * 40) * 0.6
    out = y_stereo.copy()
    peak = np.abs(out).max() + 1e-8
    out = out / peak * 0.8
    for note in notes:
        start = int(note["time"] * sr)
        end = min(out.shape[-1], start + click_len)
        n = end - start
        if n <= 0:
            continue
        out[:, start:end] += click[:n]
        if note["type"] == "hold" and "duration" in note:
            end_start = int((note["time"] + note["duration"]) * sr)
            end_end = min(out.shape[-1], end_start + click_len)
            n2 = end_end - end_start
            if n2 > 0:
                out[:, end_start:end_end] += (click[:n2] * 0.5)
    return np.clip(out, -1.0, 1.0)


LANE_COLORS = ["#ff2e9c", "#2ee6ff", "#ffb020", "#b350ff"]  # one per lane, for viz only


def visualize(instrument: str, y_mono_model_sr: np.ndarray, log_mel: np.ndarray, notes: list[dict], out_path: Path):
    duration = len(y_mono_model_sr) / onset_melspec.SAMPLE_RATE
    fig, axes = plt.subplots(3, 1, figsize=(16, 8), sharex=True,
                              gridspec_kw={"height_ratios": [2, 2, 1]})

    axes[0].plot(np.linspace(0, duration, len(y_mono_model_sr)), y_mono_model_sr, linewidth=0.4, color="steelblue")
    for note in notes:
        color = LANE_COLORS[note["lane"] % len(LANE_COLORS)]
        style = "--" if note["type"] == "hold" else "-"
        axes[0].axvline(note["time"], color=color, alpha=0.7, linewidth=0.9, linestyle=style)
        if note["type"] == "hold" and "duration" in note:
            axes[0].axvspan(note["time"], note["time"] + note["duration"], color=color, alpha=0.12)
    axes[0].set_title(f"{instrument}: waveform (color = lane, dashed = hold)")

    axes[1].imshow(log_mel, aspect="auto", origin="lower", extent=[0, duration, 0, log_mel.shape[0]], cmap="magma")
    for note in notes:
        color = LANE_COLORS[note["lane"] % len(LANE_COLORS)]
        axes[1].axvline(note["time"], color=color, alpha=0.8, linewidth=0.9)
    axes[1].set_title("log-mel spectrogram with detected notes")

    # Lane lanes as a Tapsonic-style note chart, so simultaneous (2-note) onsets are
    # visually obvious as two stacked dots at the same x position across different rows.
    for note in notes:
        color = LANE_COLORS[note["lane"] % len(LANE_COLORS)]
        marker = "s" if note["type"] == "hold" else "o"
        axes[2].scatter(note["time"], note["lane"], color=color, marker=marker, s=28, zorder=3)
        if note["type"] == "hold" and "duration" in note:
            axes[2].plot([note["time"], note["time"] + note["duration"]], [note["lane"], note["lane"]],
                         color=color, alpha=0.5, linewidth=3, zorder=2)
    axes[2].set_yticks(range(LANE_COUNT))
    axes[2].set_ylim(-0.5, LANE_COUNT - 0.5)
    axes[2].invert_yaxis()
    axes[2].set_ylabel("lane")
    axes[2].set_xlabel("time (s)")
    axes[2].set_title("lane chart (○=tap, □=hold; stacked markers at the same x = simultaneous 2-note)")
    axes[2].grid(axis="y", alpha=0.2)

    fig.tight_layout()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, dpi=110)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--reuse-stems", action="store_true",
                         help="skip demucs separation and reload previously-saved "
                              "<out_dir>/<source>_stem.wav files (for fast iteration "
                              "on onset-detection parameters)")
    args = parser.parse_args()

    input_path = Path(args.input)
    if not input_path.is_absolute():
        candidate = ML_ROOT / input_path
        input_path = candidate if candidate.exists() else Path.cwd() / input_path
    wav_path = ensure_wav(input_path)
    song_name = input_path.stem
    out_dir = OUTPUT_ROOT / song_name
    out_dir.mkdir(parents=True, exist_ok=True)

    sources = ["drums", "bass", "other", "vocals", "guitar", "piano"]
    sr = 44100
    stems = {}
    if args.reuse_stems and all((out_dir / f"{n}_stem.wav").exists() for n in sources):
        print(f"[pipeline] --reuse-stems: reloading previously separated stems from {out_dir}")
        for name in sources:
            audio, file_sr = sf.read(str(out_dir / f"{name}_stem.wav"))
            assert file_sr == sr
            stems[name] = audio.T  # [C, L]
    else:
        print("[pipeline] loading htdemucs_6s ...")
        from demucs.pretrained import get_model
        bag = get_model("htdemucs_6s")
        model = bag.models[0]
        model.eval()
        core = split.HTDemucsCore(model)
        core.eval()
        sr = model.samplerate

        print(f"[pipeline] loading audio: {wav_path}")
        data, sr = sf.read(str(wav_path))  # [N, C]
        assert sr == model.samplerate
        mix = torch.from_numpy(data.T).float().unsqueeze(0)  # [1, C, N]
        print(f"[pipeline] mix shape: {tuple(mix.shape)} ({mix.shape[-1] / sr:.1f}s)")

        t0 = time.time()
        separated = separate_full_song(model, core, mix)  # [1, S, C, L]
        print(f"[pipeline] separation done in {time.time() - t0:.1f}s")

        sources = model.sources  # [drums, bass, other, vocals, guitar, piano]
        stems = {name: separated[0, i].numpy() for i, name in enumerate(sources)}
        for name, audio in stems.items():
            sf.write(str(out_dir / f"{name}_stem.wav"), audio.T, sr, subtype="FLOAT")

    print("[pipeline] loading onset CNN ...")
    onset_model = OnsetCNN()
    onset_model.load_state_dict(torch.load(ONSET_CHECKPOINT, map_location="cpu"))
    onset_model.eval()

    import librosa
    summary = {}
    for game_instrument, source_name in GAME_INSTRUMENTS.items():
        print(f"\n[pipeline] === {game_instrument} (source: {source_name}) ===")
        y_stereo = stems[source_name]
        notes, log_mel, probs, n_onsets = detect_notes(onset_model, y_stereo, sr)

        chart_path = out_dir / f"{game_instrument}_chart.json"
        with open(chart_path, "w") as f:
            json.dump(notes, f, indent=2)

        y_mono = y_stereo.mean(axis=0)
        y_mono_model_sr = librosa.resample(y_mono, orig_sr=sr, target_sr=onset_melspec.SAMPLE_RATE)
        visualize(game_instrument, y_mono_model_sr, log_mel, notes, out_dir / f"{game_instrument}_viz.png")

        click_audio = make_click_track(y_stereo, sr, notes)
        sf.write(str(out_dir / f"{game_instrument}_click.wav"), click_audio.T, sr, subtype="FLOAT")

        n_tap = sum(1 for n in notes if n["type"] == "tap")
        n_hold = sum(1 for n in notes if n["type"] == "hold")
        duration_s = y_stereo.shape[-1] / sr
        density = len(notes) / duration_s if duration_s > 0 else 0

        # a promoted onset shows up as 2 entries sharing the exact same "time"
        from collections import Counter
        time_counts = Counter(n["time"] for n in notes)
        n_promoted_onsets = sum(1 for c in time_counts.values() if c >= 2)
        promoted_pct = (n_promoted_onsets / n_onsets * 100) if n_onsets else 0.0

        summary[game_instrument] = {
            "total_notes": len(notes), "tap": n_tap, "hold": n_hold,
            "notes_per_second": round(density, 2),
            "onsets": n_onsets, "simultaneous_onsets": n_promoted_onsets,
            "simultaneous_pct": round(promoted_pct, 1),
        }
        print(f"[pipeline] {game_instrument}: {len(notes)} notes (tap={n_tap}, hold={n_hold}), "
              f"{density:.2f} notes/sec | {n_promoted_onsets}/{n_onsets} onsets "
              f"({promoted_pct:.1f}%) promoted to simultaneous 2-lane notes")

    print("\n[pipeline] === SUMMARY ===")
    for inst, s in summary.items():
        print(f"  {inst:8s}: {s['total_notes']:4d} notes "
              f"(tap={s['tap']}, hold={s['hold']}), {s['notes_per_second']:.2f}/s, "
              f"simultaneous {s['simultaneous_onsets']}/{s['onsets']} ({s['simultaneous_pct']:.1f}%)")
    with open(out_dir / "summary.json", "w") as f:
        json.dump(summary, f, indent=2)

    print(f"\n[pipeline] done. Output in {out_dir}")


if __name__ == "__main__":
    main()
