import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        ZStack {
            NeonTheme.background
                .ignoresSafeArea()

            // Faint ambient glow behind the title — echoes the in-game combo glow so the
            // very first screen already feels like part of the same neon world.
            RadialGradient(
                colors: [NeonTheme.accent.opacity(0.25), .clear],
                center: .center, startRadius: 10, endRadius: 340
            )
            .blendMode(.screen)
            .allowsHitTesting(false)

            VStack(spacing: 36) {
                Text("JamJam")
                    .font(.system(size: 56, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: NeonTheme.accent, radius: 18)
                    .shadow(color: NeonTheme.accent, radius: 6)

                Button {
                    router.push(.songList)
                } label: {
                    Text("노래 리스트로 이동")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: 280)
                        .padding()
                        .neonCard()
                        .foregroundStyle(NeonTheme.accent)
                }
                .buttonStyle(NeonButtonStyle())
            }
        }
        .navigationBarHidden(true)
    }
}
