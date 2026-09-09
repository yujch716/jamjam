import Foundation

enum HoldState {
    case pending
    case holding(touchId: ObjectIdentifier)
    case completed(finalJudgment: Judgment)
}

/// Mutable per-play-session state for one note. A class because both the scene's per-frame
/// update loop and its touch-handling methods need to mutate the same instance in place.
final class ActiveNote {
    let runtime: RuntimeNote
    var node: NoteNode?
    var holdState: HoldState = .pending
    var isJudged: Bool = false

    /// Index of the next not-yet-scored unit (0-based). Unit 0 is scored immediately at
    /// touch-down using the standard 5-tier offset judgment; this advances from 1 onward as
    /// the per-frame sweep or a release event scores each subsequent unit exactly once.
    var nextUnitIndex: Int = 0

    init(runtime: RuntimeNote) {
        self.runtime = runtime
    }

    var startTime: Double { runtime.startTime }
    var endTime: Double? { runtime.endTime }
    var lane: Lane { runtime.lane }
    var type: NoteType { runtime.chartNote.type }
    var unitCount: Int { runtime.unitCount }

    func unitEndTime(_ index: Int) -> TimeInterval { runtime.unitEndTime(index) }
}
