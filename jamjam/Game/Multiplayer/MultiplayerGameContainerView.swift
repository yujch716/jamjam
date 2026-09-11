import SwiftUI

/// 2/4-player counterpart to `GameContainerView` — same play/result switch, but backed by
/// `MultiGameOrchestrator`'s N independent `GameState`s instead of a single one. "다시하기"
/// resets every window's state and forces fresh `RhythmScene`s (via a new `.id`); "홈으로"
/// pops the whole navigation stack through the shared router, same as the 1-player path. The
/// pause menu pauses/resumes every window at once by toggling each `GameState.isPaused` —
/// there's no per-window pause, since the menu's options (retry/leave) act on the whole
/// session, not one player's window. The menu button itself only appears in Player 1's
/// window (see `MultiplayerLayoutView`/`PauseButton`), so it can't be mistaken for another
/// player's note-touch area.
struct MultiplayerGameContainerView: View {
    let song: Song
    let instruments: [Instrument]
    @EnvironmentObject private var router: AppRouter
    @StateObject private var orchestrator: MultiGameOrchestrator
    @State private var sessionId = UUID()
    @State private var showPauseMenu = false
    @State private var pendingResumeAction: PendingResumeAction?

    init(song: Song, instruments: [Instrument]) {
        self.song = song
        self.instruments = instruments
        _orchestrator = StateObject(wrappedValue: MultiGameOrchestrator(playerCount: instruments.count))
    }

    var body: some View {
        ZStack {
            if orchestrator.allFinished {
                MultiResultView(
                    results: orchestrator.gameStates.compactMap(\.result),
                    instruments: instruments,
                    combined: orchestrator.combinedResult,
                    onRetry: restart,
                    onHome: { router.goHome() }
                )
            } else {
                MultiplayerLayoutView(song: song, gameStates: orchestrator.gameStates, instruments: instruments, onPauseTapped: pause)
                    .id(sessionId)
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
        orchestrator.gameStates.forEach { $0.isPaused = true }
    }

    private func beginCountdown(_ action: PendingResumeAction) {
        showPauseMenu = false
        pendingResumeAction = action
    }

    private func completeCountdown(_ action: PendingResumeAction) {
        pendingResumeAction = nil
        switch action {
        case .resume:
            orchestrator.gameStates.forEach { $0.isPaused = false }
        case .retry:
            restart()
        }
    }

    private func restart() {
        orchestrator.reset()
        sessionId = UUID()
    }
}
