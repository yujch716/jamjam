import Foundation

enum HoldState {
    case pending
    case holding(touchId: ObjectIdentifier, startJudgment: Judgment)
    case completed(finalJudgment: Judgment)
}

/// Mutable per-play-session state for one note. A class because both the scene's per-frame
/// update loop and its touch-handling methods need to mutate the same instance in place.
final class ActiveNote {
    let runtime: RuntimeNote
    var node: NoteNode?
    var holdState: HoldState = .pending
    var isJudged: Bool = false

    init(runtime: RuntimeNote) {
        self.runtime = runtime
    }

    var startTime: Double { runtime.startTime }
    var endTime: Double? { runtime.endTime }
    var lane: Lane { runtime.lane }
    var type: NoteType { runtime.chartNote.type }
}
