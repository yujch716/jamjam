import SwiftUI
import UIKit

enum Lane: Int, CaseIterable {
    case guitar = 0
    case drum = 1
    case bass = 2
    case piano = 3

    private var rgb: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .guitar: return (1.0, 0.18, 0.61)   // pink/magenta
        case .drum: return (0.18, 0.90, 1.0)     // cyan
        case .bass: return (1.0, 0.69, 0.13)     // yellow/orange
        case .piano: return (0.70, 0.30, 1.0)    // purple
        }
    }

    /// Neon accent color per CLAUDE.md's instrument palette (cosmetic only — no instrument is
    /// actually assigned to a lane yet, this is just for visual variety in the test screen).
    var neonColor: Color {
        let (r, g, b) = rgb
        return Color(red: r, green: g, blue: b)
    }

    /// Same color for SpriteKit (SKColor is a UIColor typealias on iOS).
    var uiColor: UIColor {
        let (r, g, b) = rgb
        return UIColor(red: r, green: g, blue: b, alpha: 1.0)
    }
}
