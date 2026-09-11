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

/// One player-count's best-ever "종합 점수/등급" for a song (CLAUDE.md 5.5 결과 화면 spec:
/// "전체 합산 점수 + 종합 등급"). Compared and replaced purely by raw `score` — see
/// `SongLibraryStore.recordBestResult`.
struct BestResult: Codable, Hashable {
    let score: Int
    let maxPossibleScore: Int
    let achievementPercent: Double
    let grade: Grade
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
    /// Set only when `status == .failed` — the actual thrown error (or, for a song found
    /// stuck in `.importing`/`.processing` at app launch, a note that the previous
    /// session was interrupted) so a future failure is diagnosable without needing a
    /// live console attached.
    var errorMessage: String?
    /// Best result ever recorded per player count (1/2/4) — completely independent per
    /// player count. Optional (rather than defaulting to `[:]`) so older persisted songs
    /// missing this key still decode instead of wiping the whole library — see
    /// `SongLibraryStore.load`.
    var bestResults: [Int: BestResult]?

    var formattedDuration: String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The single best grade across every player count this song has been played at, for
    /// a compact badge in the song list — nil if it's never been played at all.
    var bestOverallGrade: Grade? {
        bestResults?.values.max(by: { $0.achievementPercent < $1.achievementPercent })?.grade
    }
}
