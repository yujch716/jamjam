import SwiftUI

struct ResultView: View {
    let result: GameResult
    let instrument: Instrument
    let onRetry: () -> Void
    let onHome: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.10).ignoresSafeArea()

            VStack(spacing: 24) {
                PlayerResultCardView(title: instrument.label, result: result)

                HStack(spacing: 16) {
                    actionButton(title: "다시하기", tint: .cyan, action: onRetry)
                    actionButton(title: "홈으로", tint: .white, action: onHome)
                }
                .padding(.horizontal, 40)
            }
            .padding()
        }
    }

    private func actionButton(title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding()
                .background(tint.opacity(0.15))
                .foregroundStyle(tint)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(tint.opacity(0.7), lineWidth: 1)
                )
        }
    }
}
