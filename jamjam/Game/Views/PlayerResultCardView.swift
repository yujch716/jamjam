import SwiftUI

/// The per-player result breakdown (grade/achievement/judgment distribution/max combo/score),
/// shared between the single-player `ResultView` and the multiplayer result screen so both
/// stay visually consistent without duplicating this layout.
struct PlayerResultCardView: View {
    var title: String?
    let result: GameResult

    var body: some View {
        VStack(spacing: 16) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(.white.opacity(0.85))
            }

            Text(result.grade.rawValue)
                .font(.system(size: 56, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .cyan, radius: 14)

            Text(String(format: "달성률 %.1f%%", result.achievementPercent))
                .font(.subheadline.weight(.bold))
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
}
