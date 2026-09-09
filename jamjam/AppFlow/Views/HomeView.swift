import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.10)
                .ignoresSafeArea()

            VStack(spacing: 36) {
                Text("JamJam")
                    .font(.system(size: 56, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .cyan, radius: 18)
                    .shadow(color: .cyan, radius: 6)

                Button {
                    router.push(.songList)
                } label: {
                    Text("노래 리스트로 이동")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: 280)
                        .padding()
                        .background(Color.cyan.opacity(0.15))
                        .foregroundStyle(.cyan)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.cyan, lineWidth: 1)
                        )
                }
            }
        }
        .navigationBarHidden(true)
    }
}
