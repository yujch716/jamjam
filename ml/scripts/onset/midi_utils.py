"""MIDI note-onset extraction, shared by GMD (drums) and BabySlakh (bass) loaders."""
from __future__ import annotations

import pretty_midi


def onset_times_from_midi(path: str) -> list[float]:
    pm = pretty_midi.PrettyMIDI(path)
    onsets = []
    for inst in pm.instruments:
        for note in inst.notes:
            onsets.append(note.start)
    return sorted(onsets)
