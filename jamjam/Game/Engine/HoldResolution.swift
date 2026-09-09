import Foundation

/// Judges a hold note's final ("release") unit once the touch has been confirmed held at
/// least into the release grace window around the note's end time. An earlier release is a
/// premature one — the caller scores that as a Miss cascade over the remaining units
/// directly, never through this function.
func resolveHoldReleaseUnit(releaseOffsetMs: Double) -> Judgment {
    abs(releaseOffsetMs) <= Judgment.holdReleaseWindowMs ? .perfect : .bad
}
