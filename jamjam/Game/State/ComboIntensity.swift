import Foundation

/// Shared "how intense should combo-driven visuals be" calculation, used by both the
/// background glow (`ComboGlowView`) and judgment particle bursts (`RhythmScene`) — kept in
/// one place so the two effects always escalate in lockstep with each other, and with
/// `ScoreEngine.multiplier`'s own per-10-combo breakpoints, so what the player earns and
/// what they see agree.
enum ComboIntensity {
    /// 0...1, stepped every 10 combo, maxed out at 100+ combo.
    static func level(for combo: Int) -> Double {
        min(Double(combo / 10) * 0.1, 1.0)
    }
}
