import SwiftUI
import UIKit

/// Per-player-window neon color, replacing the old per-instrument lane coloring. All 4
/// lanes within one window always share the same color; single-player always uses index 0
/// (sky blue) regardless of instrument, while multiplayer gives each player's window a
/// distinct color (by its slot index) so windows can be told apart at a glance — the same
/// purpose the old per-instrument color served.
enum PlayerPalette {
    static let colors: [Color] = [
        Color(red: 0.30, green: 0.75, blue: 1.0),  // player 1 / default — sky blue
        Color(red: 1.0, green: 0.18, blue: 0.61),  // player 2 — pink/magenta
        Color(red: 1.0, green: 0.69, blue: 0.13),  // player 3 — yellow/orange
        Color(red: 0.70, green: 0.30, blue: 1.0),  // player 4 — purple
    ]

    static func color(forPlayerIndex index: Int) -> Color {
        colors[index % colors.count]
    }

    static func uiColor(forPlayerIndex index: Int) -> UIColor {
        UIColor(color(forPlayerIndex: index))
    }
}
