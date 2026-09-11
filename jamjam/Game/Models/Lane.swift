import Foundation

/// A note's on-screen column. Purely a position (0..<4) — lanes no longer carry their own
/// color; a whole window's notes share one color determined by the player, see
/// `PlayerPalette` and `RhythmScene.windowColor`.
enum Lane: Int, CaseIterable {
    case lane0 = 0
    case lane1 = 1
    case lane2 = 2
    case lane3 = 3
}
