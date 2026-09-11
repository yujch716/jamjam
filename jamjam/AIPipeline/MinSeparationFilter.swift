import Foundation

/// Port of `ml/scripts/note_classification.py`'s `filter_min_separation`: enforces a
/// minimum time gap between consecutive onsets within one instrument track by dropping
/// the weaker (lower-intensity) of any two onsets closer together than
/// `minSeparationSeconds`. Raw onset-CNN output can be dense enough to be physically
/// unplayable and visually cluttered on screen, so this thins it to a playable density
/// before lane assignment — applied after `NoteClassifier.classifyNotes` (so intensity is
/// already computed) and before `LaneAssigner.assign`.
enum MinSeparationFilter {
    /// Below this gap, the weaker onset is dropped. A module-level constant (not just a
    /// function default) since this is exactly the kind of "feel" knob expected to need
    /// re-tuning after actual play-testing — must stay in sync with
    /// `note_classification.MIN_NOTE_SEPARATION_SECONDS`.
    static let defaultMinSeparationSeconds: Double = 0.13

    /// Single left-to-right pass with backward re-checking: when an incoming note beats
    /// the last accepted one, that accepted note is popped and the incoming note is
    /// re-compared against whichever note is now last (in case removing the loser closes
    /// an now-too-small gap further back) — same shape as `PeakPicking`'s NMS loop,
    /// generalized from frame-index/probability to time/intensity.
    static func apply(
        _ notes: [NoteClassifier.RawClassifiedNote],
        minSeparationSeconds: Double = defaultMinSeparationSeconds
    ) -> [NoteClassifier.RawClassifiedNote] {
        let ordered = notes.sorted { $0.time < $1.time }
        var accepted: [NoteClassifier.RawClassifiedNote] = []
        for note in ordered {
            var current: NoteClassifier.RawClassifiedNote? = note
            while let last = accepted.last, let candidate = current,
                  candidate.time - last.time < minSeparationSeconds {
                if candidate.intensity >= last.intensity {
                    accepted.removeLast()
                } else {
                    current = nil
                }
            }
            if let current {
                accepted.append(current)
            }
        }
        return accepted
    }
}
