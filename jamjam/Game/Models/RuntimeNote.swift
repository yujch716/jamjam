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
}
