"""Shared mel-spectrogram configuration for the onset-detection pipeline.

Parameters follow Schlüter & Böck (2014) "Improved Musical Onset Detection with
Convolutional Neural Networks" (the standard lightweight-CNN onset detector this
model's design is based on): 22.05kHz audio, ~10ms hop, log-mel front end, small
context window fed to the CNN.
"""
from __future__ import annotations

import numpy as np
import librosa

SAMPLE_RATE = 22050
N_FFT = 1024
HOP_LENGTH = 220          # ~10ms at 22050Hz
N_MELS = 80
FMIN = 27.5               # ~A0
FMAX = 8000.0
FRAME_RATE = SAMPLE_RATE / HOP_LENGTH   # ~100.2 fps

# CNN input: a context window of CONTEXT_FRAMES mel frames, centered on the frame
# being classified (CONTEXT_FRAMES is odd so there's a well-defined center frame).
CONTEXT_FRAMES = 15
CONTEXT_HALF = CONTEXT_FRAMES // 2

# An onset is "close enough" to a frame if within this many frames of it — used to
# turn continuous onset timestamps into frame-level binary labels.
LABEL_TOLERANCE_FRAMES = 1

# Evaluation tolerance window (matches the standard MIREX/mir_eval onset evaluation
# convention of +/-50ms).
EVAL_TOLERANCE_SECONDS = 0.05


def load_audio(path: str, duration: float | None = None) -> np.ndarray:
    y, _ = librosa.load(path, sr=SAMPLE_RATE, mono=True, duration=duration)
    return y.astype(np.float32)


def compute_log_mel(y: np.ndarray) -> np.ndarray:
    """Returns log-mel spectrogram, shape [N_MELS, n_frames]."""
    mel = librosa.feature.melspectrogram(
        y=y, sr=SAMPLE_RATE, n_fft=N_FFT, hop_length=HOP_LENGTH,
        n_mels=N_MELS, fmin=FMIN, fmax=FMAX, power=2.0,
    )
    log_mel = librosa.power_to_db(mel, ref=np.max)
    # normalize per-file to roughly [-1, 1] range (helps a small CNN train faster/more
    # stably across files/instruments with very different loudness).
    log_mel = (log_mel - log_mel.mean()) / (log_mel.std() + 1e-6)
    return log_mel.astype(np.float32)


def onset_times_to_frame_labels(onset_times: list[float], n_frames: int) -> np.ndarray:
    """Binary label per frame: 1 if within LABEL_TOLERANCE_FRAMES of any onset time."""
    labels = np.zeros(n_frames, dtype=np.float32)
    for t in onset_times:
        center = int(round(t * FRAME_RATE))
        lo = max(0, center - LABEL_TOLERANCE_FRAMES)
        hi = min(n_frames, center + LABEL_TOLERANCE_FRAMES + 1)
        if lo < hi:
            labels[lo:hi] = 1.0
    return labels


def extract_windows(log_mel: np.ndarray, center_frames: np.ndarray) -> np.ndarray:
    """Extract CONTEXT_FRAMES-wide windows centered on the given frame indices.
    Pads with edge values at the boundaries. Returns [len(center_frames), N_MELS, CONTEXT_FRAMES].
    """
    n_mels, n_frames = log_mel.shape
    padded = np.pad(log_mel, ((0, 0), (CONTEXT_HALF, CONTEXT_HALF)), mode="edge")
    windows = np.empty((len(center_frames), n_mels, CONTEXT_FRAMES), dtype=np.float32)
    for i, c in enumerate(center_frames):
        windows[i] = padded[:, c:c + CONTEXT_FRAMES]
    return windows
