import Foundation
import Combine

enum Route: Hashable {
    case songList
    case playerSetup(Song)
    case game(instruments: [Instrument])
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

    /// Pops back to the song list, discarding player-setup/game screens above it — used by
    /// the in-game pause menu's "곡 선택 화면으로 돌아가기".
    func goToSongList() {
        path = [.songList]
    }
}
