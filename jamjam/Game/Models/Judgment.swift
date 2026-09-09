import Foundation

enum Judgment: CaseIterable, Hashable {
    case perfect
    case great
    case good
    case bad
    case miss

    var basePoints: Int {
        switch self {
        case .perfect: return 2
        case .great: return 1
        case .good: return 0
        case .bad: return 0
        case .miss: return -1
        }
    }

    var breaksCombo: Bool {
        self == .bad || self == .miss
    }

    var label: String {
        switch self {
        case .perfect: return "PERFECT"
        case .great: return "GREAT"
        case .good: return "GOOD"
        case .bad: return "BAD"
        case .miss: return "MISS"
        }
    }

    /// Upper bound of |offset| in milliseconds that still qualifies, checked in ascending strictness order.
    static let windows: [(Judgment, Double)] = [
        (.perfect, 20),
        (.great, 50),
        (.good, 100),
        (.bad, 150)
    ]

    /// Timing window used to decide whether a hold-note release landed cleanly.
    static let holdReleaseWindowMs: Double = 100

    /// A hold note is scored in fixed-size time slices ("units") rather than as one lump
    /// event, so longer holds proportionally contribute more score/combo exposure (both
    /// upside and downside) than shorter ones. See `RuntimeNote.unitCount`.
    static let holdUnitDuration: TimeInterval = 0.15
}

func judge(offsetMs: Double) -> Judgment {
    let magnitude = abs(offsetMs)
    for (judgment, bound) in Judgment.windows where magnitude <= bound {
        return judgment
    }
    return .miss
}
