import SwiftUI

/// Hosts the play/result switch for a single game session. Reached via `Route.game` from
/// `PlayerSetupView` — "다시하기" restarts this same session locally, while "홈으로" uses the
/// shared `AppRouter` to pop all the way back to Home regardless of how deep this screen sits
/// in the navigation stack.
struct GameContainerView: View {
    @EnvironmentObject private var router: AppRouter
    @StateObject private var gameState = GameState()
    @State private var playSessionId = UUID()

    var body: some View {
        Group {
            if let result = gameState.result {
                ResultView(result: result, onRetry: restart, onHome: { router.goHome() })
            } else {
                GameView(gameState: gameState)
                    .id(playSessionId)
            }
        }
        .navigationBarHidden(true)
    }

    private func restart() {
        gameState.reset()
        playSessionId = UUID()
    }
}
