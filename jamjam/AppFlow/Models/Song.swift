import Foundation

/// Matches CLAUDE.md's `Song` data model. `localFilePath` and per-instrument assets
/// (separated stems, note charts) are stored under `SongLibraryStore.songDirectory(for:)`,
/// not inline here — this struct is just the persisted index entry.
enum SongStatus: String, Codable {
    case importing
    case processing
    case ready
    case failed
}

struct Song: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    /// Filename of the original mp3 within this song's directory (see
    /// `SongLibraryStore.songDirectory(for:)`), not an absolute path — the app's container
    /// path can change between launches/installs.
    var originalFileName: String
    var duration: TimeInterval
    var status: SongStatus
    /// Instruments with at least one detected note. Only these are selectable in
    /// player/instrument setup, and only once `status == .ready`.
    var availableInstruments: [Instrument]
    var isFavorite: Bool
    var createdAt: Date

    var formattedDuration: String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
