import Foundation

/// Immutable per-note spec produced once at chart-load time: the raw chart data plus its
/// deterministically-assigned lane and a stable identity. Kept separate from `ActiveNote`
/// (which holds mutable per-play-session state) so a chart can be reloaded fresh on retry.
struct RuntimeNote: Identifiable {
    let id: UUID
    let chartNote: ChartNote
    let lane: Lane

    var startTime: Double { chartNote.time }

    var endTime: Double? {
        guard let duration = chartNote.duration else { return nil }
        return startTime + duration
    }

    /// Number of fixed `Judgment.holdUnitDuration`-sized scoring slices this note contributes.
    /// A tap is always exactly 1 unit (unchanged behavior). A hold is split into
    /// ceil(duration / holdUnitDuration) units, minimum 1, so a longer hold scores (and can
    /// be missed) proportionally more than a short one instead of counting the same as a tap.
    var unitCount: Int {
        guard chartNote.type == .hold, let duration = chartNote.duration, duration > 0 else { return 1 }
        return max(1, Int((duration / Judgment.holdUnitDuration).rounded(.up)))
    }

    /// The end time of the unit at `index` (0-based). Every boundary is clamped to the note's
    /// own `endTime`, so the final unit always ends exactly at the release point even when
    /// `duration` isn't an exact multiple of `holdUnitDuration`.
    func unitEndTime(_ index: Int) -> TimeInterval {
        let boundary = startTime + Double(index + 1) * Judgment.holdUnitDuration
        guard let end = endTime else { return boundary }
        return min(boundary, end)
    }
}
