import Foundation

enum Grade: String, Equatable {
    case sss = "SSS"
    case ss = "SS"
    case s = "S"
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"
    case f = "F"

    static func from(achievementPercent p: Double) -> Grade {
        switch p {
        case 100...: return .sss
        case 95..<100: return .ss
        case 90..<95: return .s
        case 80..<90: return .a
        case 70..<80: return .b
        case 60..<70: return .c
        case 50..<60: return .d
        default: return .f
        }
    }
}

/// Pure scoring/combo logic — no SpriteKit/SwiftUI dependency, so it can be unit-tested
/// in isolation by feeding it a sequence of final `Judgment`s.
final class ScoreEngine {
    private(set) var score: Int = 0
    private(set) var combo: Int = 0
    private(set) var maxCombo: Int = 0
    private(set) var counts: [Judgment: Int] = Dictionary(uniqueKeysWithValues: Judgment.allCases.map { ($0, 0) })

    /// Total scoring "units" in the chart — a tap counts as 1, a hold counts as its
    /// `RuntimeNote.unitCount` (see there). This, not the raw note count, is the basis for
    /// `maxPossibleScore`, since a hold note can now contribute multiple judgment events.
    let totalUnits: Int

    init(totalUnits: Int) {
        self.totalUnits = totalUnits
    }

    var multiplier: Double {
        min(1.0 + Double(combo / 10) * 0.1, 2.0)
    }

    /// Call once per scored unit (a tap has exactly one; a hold has one per
    /// `RuntimeNote.unitCount`, each judged independently as it comes due).
    @discardableResult
    func record(_ judgment: Judgment) -> Int {
        counts[judgment, default: 0] += 1

        let awarded: Int
        if judgment == .miss {
            awarded = judgment.basePoints
        } else {
            awarded = Int((Double(judgment.basePoints) * multiplier).rounded())
        }
        score += awarded

        if judgment.breaksCombo {
            combo = 0
        } else {
            combo += 1
            maxCombo = max(maxCombo, combo)
        }
        return awarded
    }

    var maxPossibleScore: Int { totalUnits * 2 }

    var achievementPercent: Double {
        guard maxPossibleScore > 0 else { return 0 }
        return (Double(score) / Double(maxPossibleScore)) * 100.0
    }

    var grade: Grade {
        Grade.from(achievementPercent: achievementPercent)
    }

    var result: GameResult {
        GameResult(
            counts: counts,
            maxCombo: maxCombo,
            score: score,
            maxPossibleScore: maxPossibleScore,
            achievementPercent: achievementPercent,
            grade: grade
        )
    }
}

struct GameResult: Equatable {
    let counts: [Judgment: Int]
    let maxCombo: Int
    let score: Int
    /// Kept alongside `achievementPercent` (rather than just the percentage) so multiple
    /// players' results can be combined into one correctly-weighted overall achievement%,
    /// even if their charts ever end up with different unit counts.
    let maxPossibleScore: Int
    let achievementPercent: Double
    let grade: Grade

    func count(_ judgment: Judgment) -> Int {
        counts[judgment, default: 0]
    }
}
