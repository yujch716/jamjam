import Foundation

/// Hardcoded stand-in for the song list until real mp3 import + on-device AI chart
/// generation are wired up. Instrument availability deliberately varies per song, mirroring
/// how real source-separation results won't always yield every instrument cleanly.
enum DummySongLibrary {
    static func makeSongs() -> [Song] {
        [
            Song(
                id: UUID(),
                title: "Neon Drive",
                duration: 138,
                availableInstruments: [.guitar, .drum, .bass, .piano],
                isFavorite: true
            ),
            Song(
                id: UUID(),
                title: "Midnight Circuit",
                duration: 165,
                availableInstruments: [.guitar, .drum, .bass],
                isFavorite: false
            ),
            Song(
                id: UUID(),
                title: "Glass City",
                duration: 121,
                availableInstruments: [.drum, .bass, .piano],
                isFavorite: true
            )
        ]
    }
}
