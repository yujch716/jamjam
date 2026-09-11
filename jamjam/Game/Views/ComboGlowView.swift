import SwiftUI

/// Ambient background glow behind the falling notes, tinted with the window's own note
/// color (see `PlayerPalette`) and growing steadily stronger as combo climbs — the "시각적
/// 보상감" CLAUDE.md's design theme calls for at high combo. Pure SwiftUI (a single
/// `RadialGradient` whose color/opacity is animated), never SpriteKit particles, so it costs
/// nothing extra per frame regardless of how many windows are on screen at once (up to 4 in
/// 4-player mode) — the judgment-burst particle density bump in `JudgmentEffects` is the only
/// place actual particle count varies with combo.
struct ComboGlowView: View {
    let combo: Int
    let color: Color

    @State private var breathe = false

    private var intensity: Double { ComboIntensity.level(for: combo) }

    var body: some View {
        RadialGradient(
            colors: [color.opacity(0.42 * intensity), color.opacity(0.16 * intensity), .clear],
            center: .center, startRadius: 20, endRadius: 520
        )
        .blendMode(.screen)
        .scaleEffect(breathe ? 1.05 : 1.0)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.4), value: intensity)
        .onChange(of: intensity) { _, newValue in
            updateBreathing(active: newValue >= 1.0)
        }
        .onAppear {
            updateBreathing(active: intensity >= 1.0)
        }
    }

    /// A slow, subtle "breathing" pulse only once combo maxes out the escalation (100+) —
    /// held off below that so lower combo tiers stay a static, cheap glow with no repeating
    /// animation running in the background at all.
    private func updateBreathing(active: Bool) {
        if active {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
                breathe = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.3)) {
                breathe = false
            }
        }
    }
}
