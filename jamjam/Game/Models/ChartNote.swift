import Foundation

struct ChartNote: Codable {
    let time: Double
    let type: NoteType
    let duration: Double?
    /// Assigned once at chart-generation time by `LaneAssigner` (see there for the random
    /// assignment + intensity-based simultaneous-2-note promotion). Optional only so the
    /// legacy `dummy_chart.json` (which predates lane assignment) still decodes — real
    /// generated charts always populate this. See `ChartLoader.loadRuntimeNotes` for the
    /// fallback used when it's missing.
    let lane: Int?
}
