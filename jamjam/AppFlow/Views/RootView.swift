import SwiftUI

/// App entry point. Wires Home → Song List → Player Setup → Game → Result together with a
/// shared `AppRouter` so "홈으로" on the result screen can pop all the way back regardless of
/// how deep the stack is.
struct RootView: View {
    @StateObject private var router = AppRouter()

    var body: some View {
        NavigationStack(path: $router.path) {
            HomeView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .songList:
                        SongListView()
                    case .playerSetup(let song):
                        PlayerSetupView(song: song)
                    case .game:
                        GameContainerView()
                    }
                }
        }
        .environmentObject(router)
        .preferredColorScheme(.dark)
        .tint(.cyan)
    }
}
