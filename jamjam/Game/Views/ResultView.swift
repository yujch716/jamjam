import SwiftUI

struct ResultView: View {
    let result: GameResult
    let onRetry: () -> Void
    let onHome: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.10).ignoresSafeArea()

            VStack(spacing: 24) {
                Text(result.grade.rawValue)
                    .font(.system(size: 72, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .cyan, radius: 16)

                Text(String(format: "달성률 %.1f%%", result.achievementPercent))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.85))

                VStack(spacing: 8) {
                    distributionRow("PERFECT", result.count(.perfect), .white)
                    distributionRow("GREAT", result.count(.great), .cyan)
                    distributionRow("GOOD", result.count(.good), .gray)
                    distributionRow("BAD", result.count(.bad), .orange)
                    distributionRow("MISS", result.count(.miss), .red)
                }
                .padding()
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.cyan.opacity(0.4), lineWidth: 1)
                )

                HStack(spacing: 32) {
                    stat("MAX COMBO", "\(result.maxCombo)")
                    stat("SCORE", "\(result.score)")
                }

                HStack(spacing: 16) {
                    actionButton(title: "다시하기", tint: .cyan, action: onRetry)
                    actionButton(title: "홈으로", tint: .white, action: onHome)
                }
                .padding(.horizontal, 40)
            }
            .padding()
        }
    }

    private func distributionRow(_ label: String, _ count: Int, _ color: Color) -> some View {
        HStack {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            Spacer()
            Text("\(count)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.6))
            Text(value)
                .font(.title3.weight(.heavy))
                .foregroundStyle(.white)
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
