"""Rule-based baseline onset detector: spectral flux with adaptive peak-picking.

Standard classic approach (Bello et al. 2005 survey; this is essentially what
librosa.onset.onset_detect implements) — used here as the "traditional algorithm"
comparison point the CNN needs to beat, per the project's evaluation requirement.
"""
from __future__ import annotations

import numpy as np
import librosa

from melspec import SAMPLE_RATE, N_FFT, HOP_LENGTH


def detect_onsets_spectral_flux(y: np.ndarray) -> np.ndarray:
    """Returns detected onset times in seconds using librosa's spectral-flux based
    onset strength + adaptive-threshold peak picking (default parameters)."""
    onset_env = librosa.onset.onset_strength(y=y, sr=SAMPLE_RATE, n_fft=N_FFT, hop_length=HOP_LENGTH)
    onset_frames = librosa.onset.onset_detect(
        onset_envelope=onset_env, sr=SAMPLE_RATE, hop_length=HOP_LENGTH, units="frames",
    )
    return librosa.frames_to_time(onset_frames, sr=SAMPLE_RATE, hop_length=HOP_LENGTH)
