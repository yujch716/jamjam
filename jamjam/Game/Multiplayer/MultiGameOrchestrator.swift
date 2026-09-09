import Foundation
import Combine

/// Owns one independent `GameState` per play window and watches all of them to know when
/// the whole multiplayer session is done (every window's own `RhythmScene` has reached its
/// own chart end and published a `result`). Each window's game logic is otherwise completely
/// untouched — this only aggregates the already-independent results.
final class MultiGameOrchestrator: ObservableObject {
    let gameStates: [GameState]
    @Published private(set) var allFinished = false

    private var cancellables: Set<AnyCancellable> = []

    init(playerCount: Int) {
        gameStates = (0..<playerCount).map { _ in GameState() }
        observe()
    }

    private func observe() {
        for gameState in gameStates {
            gameState.$result
                // `@Published`'s publisher fires from `willSet` — i.e. BEFORE the property's
                // backing storage is actually updated — so synchronously reading
                // `gameState.result` again inside this sink (which `updateCompletion` does,
                // across every game state) would see the stale pre-update value for whichever
                // state just changed, permanently undercounting by one since `result` only
                // ever sets once. Deferring to the next run loop turn lets the write land
                // first.
                .sink { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.updateCompletion()
                    }
                }
                .store(in: &cancellables)
        }
    }

    private func updateCompletion() {
        allFinished = gameStates.allSatisfy { $0.result != nil }
    }

    /// Combines every window's result into one overall achievement% (correctly weighted by
    /// each window's own max possible score, not just averaged) and maps it through the same
    /// grade thresholds as a single player's result.
    var combinedResult: (score: Int, maxPossibleScore: Int, achievementPercent: Double, grade: Grade) {
        let results = gameStates.compactMap(\.result)
        let score = results.reduce(0) { $0 + $1.score }
        let maxPossibleScore = results.reduce(0) { $0 + $1.maxPossibleScore }
        let achievementPercent = maxPossibleScore > 0 ? (Double(score) / Double(maxPossibleScore)) * 100.0 : 0
        return (score, maxPossibleScore, achievementPercent, Grade.from(achievementPercent: achievementPercent))
    }

    func reset() {
        gameStates.forEach { $0.reset() }
        allFinished = false
    }
}
