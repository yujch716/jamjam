import Foundation

/// Placeholder for the real `Song` data model (CLAUDE.md: id/title/local_file_path/duration/
/// status/isFavorite). AI chart generation and real audio aren't wired up yet, so every song
/// currently shares the same bundled dummy chart regardless of `availableInstruments`.
struct Song: Identifiable, Hashable {
    let id: UUID
    let title: String
    let duration: TimeInterval
    let availableInstruments: [Instrument]
    var isFavorite: Bool

    var formattedDuration: String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
