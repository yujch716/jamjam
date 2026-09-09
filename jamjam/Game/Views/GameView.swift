import SwiftUI
import SpriteKit

struct GameView: View {
    @ObservedObject var gameState: GameState
    @State private var scene: RhythmScene?
    @State private var loadErrorMessage: String?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.04, green: 0.05, blue: 0.10)
                    .ignoresSafeArea()
                if let scene {
                    SpriteView(scene: scene)
                        .ignoresSafeArea()
                }
                HUDView()
                    .environmentObject(gameState)
            }
            .onAppear {
                guard scene == nil else { return }
                setUpScene(size: geometry.size)
            }
        }
        .alert("채보 로드 실패", isPresented: Binding(
            get: { loadErrorMessage != nil },
            set: { if !$0 { loadErrorMessage = nil } }
        )) {
            Button("확인") { loadErrorMessage = nil }
        } message: {
            Text(loadErrorMessage ?? "")
        }
    }

    private func setUpScene(size: CGSize) {
        do {
            let notes = try ChartLoader.loadDummyChart()
            scene = RhythmScene(size: size, runtimeNotes: notes, gameState: gameState)
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }
}
