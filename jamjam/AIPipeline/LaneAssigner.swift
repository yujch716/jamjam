import Foundation

/// Port of `ml/scripts/note_classification.py`'s `assign_lanes`: gives each onset a
/// uniformly random lane, then promotes the strongest ~15-20% of onsets (by
/// `NoteClassifier.RawClassifiedNote.intensity`, the local RMS peak already computed for
/// tap/hold classification) into simultaneous 2-lane notes — so the "max 2 concurrent
/// touches per window" rule (CLAUDE.md) actually gets exercised during play instead of
/// sitting unused. Must stay parameter-for-parameter identical to the Python version.
enum LaneAssigner {
    private struct Placed {
        let time: Double
        let lane: Int
    }

    /// - Regular notes: a uniformly random lane, independent of every other note — a
    ///   repeated lane (even back-to-back) is a normal, allowed outcome, not something to
    ///   avoid.
    /// - The top `simultaneousRatio` fraction of notes by `intensity` are promoted to 2
    ///   simultaneous notes in 2 different lanes, as long as 2 lanes are free of any other
    ///   note within `collisionWindow` seconds of this onset. If fewer than 2 lanes are
    ///   free, the promotion is skipped and the note falls back to a single random lane,
    ///   same as any other note.
    /// - A promoted hold note keeps the same type/duration in both lanes.
    static func assign<G: RandomNumberGenerator>(
        _ notes: [NoteClassifier.RawClassifiedNote],
        laneCount: Int = 4,
        simultaneousRatio: Double = 0.175,
        collisionWindow: Double = 0.15,
        rng: inout G
    ) -> [ChartNote] {
        let ordered = notes.sorted { $0.time < $1.time }

        let promoteCount = Int((Double(ordered.count) * simultaneousRatio).rounded())
        var promoteIndices = Set<Int>()
        if promoteCount > 0 {
            let byIntensity = ordered.enumerated().sorted { $0.element.intensity > $1.element.intensity }
            promoteIndices = Set(byIntensity.prefix(promoteCount).map { $0.offset })
        }

        var placed: [Placed] = []
        var result: [ChartNote] = []

        for (index, note) in ordered.enumerated() {
            let nearbyLanes = Set(placed.filter { abs($0.time - note.time) <= collisionWindow }.map { $0.lane })
            let freeLanes = (0..<laneCount).filter { !nearbyLanes.contains($0) }

            let lanes: [Int]
            if promoteIndices.contains(index), freeLanes.count >= 2 {
                lanes = Array(freeLanes.shuffled(using: &rng).prefix(2))
            } else {
                lanes = [Int.random(in: 0..<laneCount, using: &rng)]
            }

            for lane in lanes {
                result.append(ChartNote(time: note.time, type: note.type, duration: note.duration, lane: lane))
                placed.append(Placed(time: note.time, lane: lane))
            }
        }

        return result.sorted { $0.time < $1.time }
    }
}
