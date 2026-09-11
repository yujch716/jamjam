import SwiftUI

/// Shared "탭소닉 스타일" neon look for the pre-game screens (Home/노래 리스트/인원·악기
/// 선택) — the game screen already has its own glow via `ComboGlowView`/`JudgmentEffects`;
/// this is the SwiftUI-only equivalent so the surrounding chrome doesn't feel like a
/// different app (CLAUDE.md 3.6 디자인 테마).
enum NeonTheme {
    static let background = Color(red: 0.04, green: 0.05, blue: 0.10)
    /// The default accent for every pre-game screen — none of these are ever a specific
    /// multiplayer window, so they always use the same sky blue player 1 uses in-game (see
    /// `PlayerPalette`), never an instrument color.
    static let accent = PlayerPalette.color(forPlayerIndex: 0)
}

/// Press feedback (scale + brightness lift) for any neon button — replaces the default
/// flat tap response with something snappier and more game-like.
struct NeonButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .brightness(configuration.isPressed ? 0.10 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// Dark card background + neon border + soft glow — CLAUDE.md's "UI 컴포넌트는 어두운
    /// 카드 배경 + 네온 테두리/글로우 라인" look, as one reusable modifier.
    func neonCard(tint: Color = NeonTheme.accent, cornerRadius: CGFloat = 14, lineWidth: CGFloat = 1) -> some View {
        self
            .background(tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(tint.opacity(0.7), lineWidth: lineWidth)
            )
            .shadow(color: tint.opacity(0.35), radius: 8)
    }
}
