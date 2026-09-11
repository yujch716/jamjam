import SwiftUI

/// Hosts the play/result switch for a single game session. Reached via `Route.game` from
/// `PlayerSetupView` — "다시하기" restarts this same session locally, "홈으로"/pause-menu's
/// song-list option use the shared `AppRouter` to jump back regardless of how deep this
/// screen sits in the navigation stack.
struct GameContainerView: View {
    let song: Song
    let instrument: Instrument
    @EnvironmentObject private var router: AppRouter
    @StateObject private var gameState = GameState()
    @State private var playSessionId = UUID()
    @State private var showPauseMenu = false
    @State private var pendingResumeAction: PendingResumeAction?

    var body: some View {
        ZStack {
            if let result = gameState.result {
                ResultView(result: result, instrument: instrument, onRetry: restart, onHome: { router.goHome() })
            } else {
                GameView(
                    gameState: gameState, instrument: instrument,
                    chartLoader: { try ChartLoader.loadRuntimeNotes(fromFileURL: SongLibraryStore.shared.chartURL(for: song, instrument: instrument)) },
                    // Plays the original mixed song, not the separated stem — the stem is
                    // only ever used offline to generate the chart's onset timings. What
                    // the player actually hears during play must always be the real song.
                    audioLoader: { AudioPlaybackController(fileURL: SongLibraryStore.shared.originalFileURL(for: song)) },
                    onPauseTapped: pause
                )
                    .id(playSessionId)
            }

            if showPauseMenu {
                PauseMenuOverlay(
                    onResume: { beginCountdown(.resume) },
                    onRetry: { beginCountdown(.retry) },
                    onGoToSongList: { router.goToSongList() }
                )
            }

            if let action = pendingResumeAction {
                CountdownOverlayView(onFinished: { completeCountdown(action) })
            }
        }
        .navigationBarHidden(true)
        .ignoresSafeArea()
    }

    private func pause() {
        showPauseMenu = true
        gameState.isPaused = true
    }

    /// Closes the menu but keeps the game paused/frozen (and, for a retry, not yet reset)
    /// until the countdown actually finishes — see `completeCountdown`.
    private func beginCountdown(_ action: PendingResumeAction) {
        showPauseMenu = false
        pendingResumeAction = action
    }

    private func completeCountdown(_ action: PendingResumeAction) {
        pendingResumeAction = nil
        switch action {
        case .resume:
            gameState.isPaused = false
        case .retry:
            restart()
        }
    }

    private func restart() {
        gameState.reset()
        playSessionId = UUID()
    }
}
