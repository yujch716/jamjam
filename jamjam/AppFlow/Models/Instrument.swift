import SwiftUI

/// A song-level concept: which instrument tracks are available/selectable for a song.
/// Kept separate from `Lane` (the in-game note-column assignment) even though they share
/// the same 4 cases and colors today — once real per-instrument charts exist, a single
/// instrument's play window may span multiple lanes, so the two will diverge.
enum Instrument: String, CaseIterable, Hashable, Codable {
    case guitar
    case drum
    case bass
    case piano

    var displayName: String {
        switch self {
        case .guitar: return "기타"
        case .drum: return "드럼"
        case .bass: return "베이스"
        case .piano: return "피아노"
        }
    }

    var emoji: String {
        switch self {
        case .guitar: return "🎸"
        case .drum: return "🥁"
        case .bass: return "🎻"
        case .piano: return "🎹"
        }
    }

    /// "🎸 기타" — the combined label used wherever a window/card needs to identify its
    /// instrument at a glance (game HUD badge, result screen cards).
    var label: String { "\(emoji) \(displayName)" }

    var neonColor: Color {
        switch self {
        case .guitar: return Color(red: 1.0, green: 0.18, blue: 0.61)
        case .drum: return Color(red: 0.18, green: 0.90, blue: 1.0)
        case .bass: return Color(red: 1.0, green: 0.69, blue: 0.13)
        case .piano: return Color(red: 0.70, green: 0.30, blue: 1.0)
        }
    }
}
