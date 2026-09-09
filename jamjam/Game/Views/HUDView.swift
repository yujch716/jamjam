import SwiftUI

struct HUDView: View {
    @EnvironmentObject var gameState: GameState

    /// The hosting window's height, used to scale every font here relative to a full-screen
    /// 1-player window — so the same HUD reads correctly whether it's filling the whole
    /// screen or squeezed into a quarter of it in 4-player mode. Defaults to a typical
    /// full-height iPad portrait window (scale ≈ 1.0) for the 1-player call site, which never
    /// needs to pass this explicitly.
    var windowHeight: CGFloat = HUDView.referenceWindowHeight
    /// Which instrument this window is playing — shown as a small badge so a grid of
    /// otherwise-identical multiplayer windows can be told apart at a glance. `nil` hides it.
    var instrument: Instrument? = nil

    static let referenceWindowHeight: CGFloat = 1180

    private var scale: CGFloat { windowHeight / Self.referenceWindowHeight }
    private func scaled(_ size: CGFloat, min minSize: CGFloat) -> CGFloat {
        max(minSize, size * scale)
    }

    var body: some View {
        ZStack {
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 4 * scale) {
                        Text("SCORE")
                            .font(.system(size: scaled(13, min: 8), weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("\(gameState.score)")
                            .font(.system(size: scaled(28, min: 14), weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    if let instrument {
                        InstrumentBadgeView(instrument: instrument, fontSize: scaled(15, min: 9))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4 * scale) {
                        Text("COMBO")
                            .font(.system(size: scaled(13, min: 8), weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("\(gameState.combo)")
                            .font(.system(size: scaled(28, min: 14), weight: .heavy, design: .rounded))
                            .foregroundStyle(.cyan)
                    }
                }
                .padding(8 * scale)

                Spacer()

                if let popup = gameState.lastJudgment {
                    JudgmentPopupView(judgment: popup.judgment, fontSize: scaled(22, min: 12))
                        .id(popup.id)
                        .padding(.bottom, 140 * scale)
                }
            }

            // Big, always-visible center combo counter — separate from the corner mini-HUD
            // above, and positioned by the ZStack's own centering so it never collides with
            // the top-anchored score/combo row or the bottom-anchored judgment popup. Shows
            // even at 0 so a Bad/Miss combo break reads as an immediate, visible reset rather
            // than the number just quietly disappearing.
            ComboCounterView(combo: gameState.combo, fontSize: scaled(100, min: 28))
        }
        .allowsHitTesting(false)
    }
}

private struct InstrumentBadgeView: View {
    let instrument: Instrument
    let fontSize: CGFloat

    var body: some View {
        Text(instrument.label)
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .foregroundStyle(instrument.neonColor)
            .padding(.horizontal, fontSize * 0.6)
            .padding(.vertical, fontSize * 0.3)
            .background(instrument.neonColor.opacity(0.15))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(instrument.neonColor.opacity(0.6), lineWidth: 1))
    }
}

private struct ComboCounterView: View {
    let combo: Int
    let fontSize: CGFloat
    @State private var popScale: CGFloat = 1.0

    var body: some View {
        Text("\(combo)")
            .font(.system(size: fontSize, weight: .heavy, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .shadow(color: .cyan, radius: fontSize * 0.2)
            .shadow(color: .cyan, radius: fontSize * 0.08)
            .scaleEffect(popScale)
            .onChange(of: combo) { _, _ in
                popScale = 1.0
                withAnimation(.easeOut(duration: 0.08)) {
                    popScale = 1.18
                }
                withAnimation(.easeOut(duration: 0.2).delay(0.08)) {
                    popScale = 1.0
                }
            }
    }
}

private struct JudgmentPopupView: View {
    let judgment: Judgment
    let fontSize: CGFloat
    @State private var faded = false

    var body: some View {
        Text(judgment.label)
            .font(.system(size: fontSize, weight: .heavy, design: .rounded))
            .foregroundStyle(color)
            .shadow(color: color, radius: fontSize * 0.45)
            .shadow(color: color, radius: fontSize * 0.18)
            .opacity(faded ? 0 : 1)
            .scaleEffect(faded ? 1.2 : 0.9)
            .onAppear {
                withAnimation(.easeOut(duration: 0.45)) {
                    faded = true
                }
            }
    }

    private var color: Color {
        switch judgment {
        case .perfect: return .white
        case .great: return .cyan
        case .good: return .gray
        case .bad: return .orange
        case .miss: return .red
        }
    }
}
