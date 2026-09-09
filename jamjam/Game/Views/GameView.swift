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
                if let scene {
                    SpriteView(scene: scene)
                }
                HUDView()
                    .environmentObject(gameState)
            }
            .onAppear {
                guard scene == nil else { return }
                setUpScene(size: geometry.size)
            }
            .onChange(of: geometry.size) { _, newSize in
                // Keeps the scene's coordinate space exactly matching the SKView's actual
                // bounds (lane x-ranges and the judgment hit-test y-range are both derived
                // from `size`) — without this, a layout pass that settles after the first
                // frame (safe area/orientation finalizing, which can happen later on a real
                // device than in the simulator) would leave touch hit-testing misaligned with
                // where notes are actually drawn.
                scene?.size = newSize
            }
        }
        .ignoresSafeArea()
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
