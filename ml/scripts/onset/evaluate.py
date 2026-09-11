"""Onset evaluation: greedy tolerance-window matching (the standard MIREX/mir_eval
onset F-measure convention — each detected onset may match at most one reference
onset, and vice versa, within +/-EVAL_TOLERANCE_SECONDS)."""
from __future__ import annotations

import numpy as np

from melspec import EVAL_TOLERANCE_SECONDS


def match_onsets(reference: np.ndarray, estimated: np.ndarray, tolerance: float = EVAL_TOLERANCE_SECONDS):
    """Greedy one-to-one matching within `tolerance` seconds. Returns (n_matched, n_ref, n_est)."""
    reference = np.sort(np.asarray(reference, dtype=float))
    estimated = np.sort(np.asarray(estimated, dtype=float))
    matched_ref = np.zeros(len(reference), dtype=bool)
    matched_est = np.zeros(len(estimated), dtype=bool)

    j = 0
    for i, r in enumerate(reference):
        # advance j to the first estimate that could plausibly match
        while j < len(estimated) and estimated[j] < r - tolerance:
            j += 1
        # search forward from j for the closest unmatched estimate within tolerance
        best_k, best_dist = -1, None
        k = j
        while k < len(estimated) and estimated[k] <= r + tolerance:
            if not matched_est[k]:
                dist = abs(estimated[k] - r)
                if best_dist is None or dist < best_dist:
                    best_dist, best_k = dist, k
            k += 1
        if best_k >= 0:
            matched_ref[i] = True
            matched_est[best_k] = True

    return int(matched_ref.sum()), len(reference), len(estimated)


def precision_recall_f1(n_matched: int, n_ref: int, n_est: int):
    precision = n_matched / n_est if n_est > 0 else (1.0 if n_ref == 0 else 0.0)
    recall = n_matched / n_ref if n_ref > 0 else (1.0 if n_est == 0 else 0.0)
    f1 = 2 * precision * recall / (precision + recall) if (precision + recall) > 0 else 0.0
    return precision, recall, f1


def evaluate_corpus(pairs: list[tuple[np.ndarray, np.ndarray]], tolerance: float = EVAL_TOLERANCE_SECONDS):
    """pairs: list of (reference_onsets, estimated_onsets) per file.
    Returns micro-averaged (precision, recall, f1) across the whole corpus."""
    total_matched = total_ref = total_est = 0
    for ref, est in pairs:
        m, r, e = match_onsets(ref, est, tolerance)
        total_matched += m
        total_ref += r
        total_est += e
    return precision_recall_f1(total_matched, total_ref, total_est)
