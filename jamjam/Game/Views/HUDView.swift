import SwiftUI

struct HUDView: View {
    @EnvironmentObject var gameState: GameState

    var body: some View {
        ZStack {
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SCORE")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("\(gameState.score)")
                            .font(.system(.title, design: .rounded).weight(.heavy))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("COMBO")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("\(gameState.combo)")
                            .font(.system(.title, design: .rounded).weight(.heavy))
                            .foregroundStyle(.cyan)
                    }
                }
                .padding()

                Spacer()

                if let popup = gameState.lastJudgment {
                    JudgmentPopupView(judgment: popup.judgment)
                        .id(popup.id)
                        .padding(.bottom, 140)
                }
            }

            // Big, always-visible center combo counter — separate from the corner mini-HUD
            // above, and positioned by the ZStack's own centering so it never collides with
            // the top-anchored score/combo row or the bottom-anchored judgment popup. Shows
            // even at 0 so a Bad/Miss combo break reads as an immediate, visible reset rather
            // than the number just quietly disappearing.
            ComboCounterView(combo: gameState.combo)
        }
        .allowsHitTesting(false)
    }
}

private struct ComboCounterView: View {
    let combo: Int
    @State private var popScale: CGFloat = 1.0

    var body: some View {
        Text("\(combo)")
            .font(.system(size: 100, weight: .heavy, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .shadow(color: .cyan, radius: 20)
            .shadow(color: .cyan, radius: 8)
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
    @State private var faded = false

    var body: some View {
        Text(judgment.label)
            .font(.system(.title2, design: .rounded).weight(.heavy))
            .foregroundStyle(color)
            .shadow(color: color, radius: 10)
            .shadow(color: color, radius: 4)
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
