import Foundation
import Combine

struct JudgmentPopup: Identifiable {
    let id = UUID()
    let judgment: Judgment
}

/// Shared between the SpriteKit scene (which mutates it as notes are judged) and the
/// SwiftUI HUD/result screen (which observes it). Single-scene, single-owner — no delegate
/// protocol needed for this scope.
final class GameState: ObservableObject {
    @Published var score: Int = 0
    @Published var combo: Int = 0
    @Published var lastJudgment: JudgmentPopup?
    @Published var result: GameResult?
    /// Set by the pause menu, observed by `GameView` to pause/resume its own `RhythmScene`
    /// (which also shifts its internal timeline by however long it was paused).
    @Published var isPaused: Bool = false

    func reset() {
        score = 0
        combo = 0
        lastJudgment = nil
        result = nil
        isPaused = false
    }
}
