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

    func delete(_ song: Song) {
        songs.removeAll { $0.id == song.id }
        try? fileManager.removeItem(at: songDirectory(for: song))
        save()
    }

    /// Registers a new song in `.importing` state and copies the source file into its
    /// directory. Returns the new `Song` so the caller can immediately kick off chart
    /// generation against it.
    func beginImport(sourceURL: URL, title: String) throws -> Song {
        let id = UUID()
        var song = Song(
            id: id, title: title, originalFileName: sourceURL.lastPathComponent,
            duration: 0, status: .importing, availableInstruments: [], isFavorite: false,
            createdAt: Date()
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

    func markFailed(_ songID: UUID) {
        guard let index = songs.firstIndex(where: { $0.id == songID }) else { return }
        songs[index].status = .failed
        save()
    }
}
