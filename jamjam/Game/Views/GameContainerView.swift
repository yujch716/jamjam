import SwiftUI

/// Root of the game screen. No home screen / song list exists yet, so this is wired
/// directly as the app's entry point. Local enum-free state switch (no router needed
/// for two screens) — retry and home both just reset and restart the same chart for now.
struct GameContainerView: View {
    @StateObject private var gameState = GameState()
    @State private var playSessionId = UUID()

    var body: some View {
        Group {
            if let result = gameState.result {
                ResultView(result: result, onRetry: restart, onHome: restart)
            } else {
                GameView(gameState: gameState)
                    .id(playSessionId)
            }
        }
    }

    private func restart() {
        gameState.reset()
        playSessionId = UUID()
    }
}
