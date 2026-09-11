import Combine
import Foundation

/// Local persistence for the song library — CLAUDE.md's "로컬 저장, 서버 없음" data model.
/// Directory layout per song, under `Documents/Songs/<song.id>/`:
///   original.<ext>          the imported mp3, kept verbatim
///   stems/<instrument>.wav  separated audio for each detected instrument
///   charts/<instrument>.json  note_chart for each detected instrument
/// The index of all songs (metadata only, not the audio/chart files) is a single JSON
/// array at `Documents/songs_index.json`.
@MainActor
final class SongLibraryStore: ObservableObject {
    static let shared = SongLibraryStore()

    @Published private(set) var songs: [Song] = []

    private let fileManager = FileManager.default

    private var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var songsRootURL: URL {
        documentsURL.appendingPathComponent("Songs", isDirectory: true)
    }
    private var indexURL: URL {
        documentsURL.appendingPathComponent("songs_index.json")
    }

    private init() {
        load()
        failStuckImports()
    }

    /// A song can be left in `.importing`/`.processing` forever if the app was
    /// suspended or killed mid-pipeline (e.g. the screen locked, or the user
    /// backgrounded the app, during the tens of seconds a long song takes to process)
    /// — there's no way to resume a half-finished import, so mark these failed on next
    /// launch instead of leaving them stuck showing "채보 생성 중..." forever.
    private func failStuckImports() {
        var changed = false
        for index in songs.indices where songs[index].status == .importing || songs[index].status == .processing {
            songs[index].status = .failed
            songs[index].errorMessage = "이전 시도가 중간에 중단됐어요 (화면이 잠기거나 앱이 백그라운드로 전환되면 처리가 멈출 수 있어요)."
            changed = true
        }
        if changed { save() }
    }

    // MARK: - Paths

    func songDirectory(for song: Song) -> URL {
        songsRootURL.appendingPathComponent(song.id.uuidString, isDirectory: true)
    }

    func originalFileURL(for song: Song) -> URL {
        songDirectory(for: song).appendingPathComponent(song.originalFileName)
    }

    func stemsDirectory(for song: Song) -> URL {
        songDirectory(for: song).appendingPathComponent("stems", isDirectory: true)
    }

    func stemURL(for song: Song, instrument: Instrument) -> URL {
        stemsDirectory(for: song).appendingPathComponent("\(instrument.rawValue).wav")
    }

    func chartsDirectory(for song: Song) -> URL {
        songDirectory(for: song).appendingPathComponent("charts", isDirectory: true)
    }

    func chartURL(for song: Song, instrument: Instrument) -> URL {
        chartsDirectory(for: song).appendingPathComponent("\(instrument.rawValue).json")
    }

    // MARK: - Index persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Song].self, from: data) else {
            songs = []
            return
        }
        songs = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(songs) else { return }
        try? fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Mutations

    func toggleFavorite(_ song: Song) {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        songs[index].isFavorite.toggle()
        save()
    }

    /// Removes the song from the index AND its entire on-disk directory (original mp3 +
    /// every separated stem + every instrument's note_chart — everything lives under
    /// `songDirectory(for:)`, so one recursive removal is enough to reclaim all of it).
    /// Returns `false` if the on-disk removal failed (index removal still proceeds either
    /// way — a broken/orphaned entry helps no one) so the caller can surface that instead
    /// of silently leaving files behind.
    @discardableResult
    func delete(_ song: Song) -> Bool {
        let dir = songDirectory(for: song)
        var diskRemovalSucceeded = true
        if fileManager.fileExists(atPath: dir.path) {
            do {
                try fileManager.removeItem(at: dir)
            } catch {
                diskRemovalSucceeded = false
            }
        }
        songs.removeAll { $0.id == song.id }
        save()
        return diskRemovalSucceeded
    }

    /// Registers a new song in `.importing` state and copies the source file into its
    /// directory. Returns the new `Song` so the caller can immediately kick off chart
    /// generation against it.
    func beginImport(sourceURL: URL, title: String) throws -> Song {
        let id = UUID()
        var song = Song(
            id: id, title: title, originalFileName: sourceURL.lastPathComponent,
            duration: 0, status: .importing, availableInstruments: [], isFavorite: false,
            createdAt: Date(), errorMessage: nil
        )
        let dir = songDirectory(for: song)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(sourceURL.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)

        songs.insert(song, at: 0)
        save()
        song.originalFileName = sourceURL.lastPathComponent
        return song
    }

    func updateStatus(_ songID: UUID, to status: SongStatus) {
        guard let index = songs.firstIndex(where: { $0.id == songID }) else { return }
        songs[index].status = status
        save()
    }

    func finalizeImport(_ songID: UUID, duration: TimeInterval, availableInstruments: [Instrument]) {
        guard let index = songs.firstIndex(where: { $0.id == songID }) else { return }
        songs[index].duration = duration
        songs[index].availableInstruments = availableInstruments
        songs[index].status = .ready
        save()
    }

    func markFailed(_ songID: UUID, reason: String? = nil) {
        guard let index = songs.firstIndex(where: { $0.id == songID }) else { return }
        songs[index].status = .failed
        songs[index].errorMessage = reason
        save()
    }
}
