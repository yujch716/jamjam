import SwiftUI
import SpriteKit

/// One independent play window: its own `RhythmScene` + `GameState`, reused as-is whether
/// it fills the whole screen (1-player) or one cell of a multiplayer grid. `chartLoader`
/// defaults to the shared dummy chart everyone uses today, but is a real closure (not a
/// hardcoded call) so a future per-instrument chart can be handed to a specific window
/// without changing this type.
///
/// Deliberately does NOT call `.ignoresSafeArea()` itself — the caller applies that once at
/// whatever level actually spans the full screen (a single call site for 1-player, or the
/// whole multiplayer grid for 2P/4P), so this view just fills whatever frame it's given.
struct GameView: View {
    @ObservedObject var gameState: GameState
    /// Which instrument this window is playing — shown as a small badge in its own HUD so a
    /// multiplayer grid of otherwise-identical windows can be told apart at a glance.
    var instrument: Instrument? = nil
    var chartLoader: () throws -> [RuntimeNote] = ChartLoader.loadDummyChart
    /// Builds this window's audio player (the separated instrument stem), if any — nil
    /// for the dummy-chart path, which has no backing audio file.
    var audioLoader: () -> AudioPlaybackController? = { nil }
    /// Diagnostic-only tag forwarded to `RhythmScene` (see there) — empty for the 1-player
    /// call site, distinct per slot in multiplayer.
    var windowLabel: String = ""
    /// Non-nil only for the one window that should show the pause button in its own HUD (the
    /// single window in 1-player, or specifically Player 1's in multiplayer) — see
    /// `PauseButton`'s doc comment for why this lives per-window instead of floating at a
    /// fixed screen position.
    var onPauseTapped: (() -> Void)? = nil

    @State private var scene: RhythmScene?
    @State private var loadErrorMessage: String?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.04, green: 0.05, blue: 0.10)
                if let scene {
                    SpriteView(scene: scene)
                }
                HUDView(windowHeight: geometry.size.height, instrument: instrument)
                    .environmentObject(gameState)

                if let onPauseTapped {
                    let scale = geometry.size.height / HUDView.referenceWindowHeight
                    VStack {
                        HStack {
                            Spacer()
                            PauseButton(action: onPauseTapped)
                                .padding(.trailing, 16)
                                // Clears this window's own SCORE/COMBO HUD row, scaled the
                                // same way HUDView scales its fonts so this still sits just
                                // below that row in a smaller multiplayer window.
                                .padding(.top, 70 * scale)
                        }
                        Spacer()
                    }
                }
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
            .onChange(of: gameState.isPaused) { _, isPaused in
                scene?.setPaused(isPaused)
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
            let notes = try chartLoader()
            let audioPlayer = audioLoader()
            scene = RhythmScene(size: size, runtimeNotes: notes, gameState: gameState, windowLabel: windowLabel,
                                 audioPlayer: audioPlayer)
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }
}
