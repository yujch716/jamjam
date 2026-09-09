import SwiftUI

struct HUDView: View {
    @EnvironmentObject var gameState: GameState

    var body: some View {
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
        .allowsHitTesting(false)
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
