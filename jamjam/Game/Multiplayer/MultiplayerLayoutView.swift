import SwiftUI

/// Arranges 2 or 4 independent `GameView` windows on one screen.
///
/// Slot index convention: 0 = bottom(-left), 1 = bottom-right (4P only) / top (2P), 2 =
/// top-left (4P only), 3 = top-right (4P only). `instruments[i]` must line up with
/// `gameStates[i]` — both come from the same ordered selection made in `PlayerSetupView`.
///
/// Orientation: the bottom row plays in the normal (1-player) orientation — judgment zone at
/// the screen's outer/bottom edge, notes falling toward it. The top row is rotated 180° as a
/// whole (never left-right mirrored), so its judgment zone sits at the screen's outer/top
/// edge instead — for two people sitting face-to-face across the iPad, each sees notes fall
/// away from center toward their own near edge. `RhythmScene` itself has no concept of
/// orientation; the rotation is purely a SwiftUI transform on top of the same reusable window.
struct MultiplayerLayoutView: View {
    let song: Song
    let gameStates: [GameState]
    let instruments: [Instrument]
    /// Wired only into Player 1's window (index 0) — see `PauseButton`'s doc comment for why
    /// the menu button lives inside one specific window's own HUD rather than floating at a
    /// fixed screen position shared by all of them.
    var onPauseTapped: (() -> Void)? = nil

    /// One shared player for the whole session, not one per window — every window plays
    /// the same original mixed song (never the separated stems, which exist only to
    /// generate each window's chart), so N independent players would just be N
    /// out-of-phase copies of the same audio playing over each other. `play()`/`pause()`/
    /// `resume()` are all idempotent, so each window calling them independently (via its
    /// own `RhythmScene`) on this one shared instance is harmless.
    private let sharedAudioPlayer: AudioPlaybackController?

    init(song: Song, gameStates: [GameState], instruments: [Instrument], onPauseTapped: (() -> Void)? = nil) {
        self.song = song
        self.gameStates = gameStates
        self.instruments = instruments
        self.onPauseTapped = onPauseTapped
        self.sharedAudioPlayer = AudioPlaybackController(fileURL: SongLibraryStore.shared.originalFileURL(for: song))
    }

    var body: some View {
        switch gameStates.count {
        case 2:
            VStack(spacing: 2) {
                window(1, label: "P2-top")
                    .rotationEffect(.degrees(180))
                window(0, label: "P1-bottom")
            }
        case 4:
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    window(2, label: "P3-topLeft")
                    window(3, label: "P4-topRight")
                }
                .rotationEffect(.degrees(180))
                HStack(spacing: 2) {
                    window(0, label: "P1-bottomLeft")
                    window(1, label: "P2-bottomRight")
                }
            }
        default:
            window(0, label: "P1")
        }
    }

    private func window(_ index: Int, label: String) -> some View {
        let instrument = instruments.indices.contains(index) ? instruments[index] : nil
        return GameView(
            gameState: gameStates.indices.contains(index) ? gameStates[index] : GameState(),
            instrument: instrument,
            chartLoader: {
                guard let instrument else { throw ChartLoaderError.resourceNotFound }
                return try ChartLoader.loadRuntimeNotes(fromFileURL: SongLibraryStore.shared.chartURL(for: song, instrument: instrument))
            },
            audioLoader: { sharedAudioPlayer },
            windowLabel: label,
            onPauseTapped: index == 0 ? onPauseTapped : nil
        )
        .clipped()
    }
}
