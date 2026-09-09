import Foundation
import Combine

enum Route: Hashable {
    case songList
    case playerSetup(Song)
    case game
}

/// Single source of truth for the navigation stack, shared via environment so any screen
/// (notably the result screen, several levels deep) can jump straight back to Home without
/// threading a callback through every intermediate view.
final class AppRouter: ObservableObject {
    @Published var path: [Route] = []

    func push(_ route: Route) {
        path.append(route)
    }

    func goHome() {
        path.removeAll()
    }
}
