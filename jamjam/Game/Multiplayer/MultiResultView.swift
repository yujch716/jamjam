import SwiftUI

struct MultiResultView: View {
    let results: [GameResult]
    let instruments: [Instrument]
    let combined: (score: Int, maxPossibleScore: Int, achievementPercent: Double, grade: Grade)
    let onRetry: () -> Void
    let onHome: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.10).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 6) {
                        Text("종합 등급 \(combined.grade.rawValue)")
                            .font(.system(size: 40, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(color: .cyan, radius: 14)
                        Text("합산 점수 \(combined.score) · 달성률 \(String(format: "%.1f", combined.achievementPercent))%")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.top, 24)

                    LazyVGrid(columns: gridColumns, spacing: 16) {
                        ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                            let instrument = instruments.indices.contains(index) ? instruments[index] : nil
                            let title = instrument.map { "PLAYER \(index + 1) · \($0.label)" } ?? "PLAYER \(index + 1)"
                            PlayerResultCardView(title: title, result: result)
                                .padding()
                                .background(Color.white.opacity(0.03))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke((instrument?.neonColor ?? .white).opacity(0.3), lineWidth: 1)
                                )
                        }
                    }
                    .padding(.horizontal)

                    HStack(spacing: 16) {
                        actionButton(title: "다시하기", tint: .cyan, action: onRetry)
                        actionButton(title: "홈으로", tint: .white, action: onHome)
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private var gridColumns: [GridItem] {
        results.count > 2
            ? [GridItem(.flexible()), GridItem(.flexible())]
            : [GridItem(.flexible())]
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
