import Foundation

/// Collapses a hold note's start+release sub-outcomes into exactly one final judgment,
/// so every note (tap or hold) contributes a single score event — matching the
/// "max score = note count × 2" formula.
///
/// - heldContinuously: false if the touch was lifted (or cancelled) before the release
///   grace window opened, i.e. an early release.
/// - releaseOffsetMs: (releaseElapsed - targetEndTime) * 1000, or nil if the hold was
///   never released (still down when the deadline swept it up as abandoned).
func resolveHoldOutcome(
    startJudgment: Judgment,
    heldContinuously: Bool,
    releaseOffsetMs: Double?
) -> Judgment {
    guard heldContinuously else { return .miss }
    guard let offset = releaseOffsetMs, abs(offset) <= Judgment.holdReleaseWindowMs else {
        return .bad
    }
    return startJudgment
}
