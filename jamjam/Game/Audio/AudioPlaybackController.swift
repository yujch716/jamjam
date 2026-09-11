import AVFoundation
import Foundation

/// Plays one instrument's separated stem in sync with `RhythmScene`'s note timeline.
/// `RhythmScene` calls `play()` from `didMove(to:)` (so audio starts at essentially the
/// same wall-clock moment the scene's own `update(_:)` loop begins, keeping the two
/// clocks aligned within a frame or two) and `pause()`/`resume()` in lockstep with its
/// own `setPaused(_:)`, so the pause menu freezes/resumes both together.
final class AudioPlaybackController {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let file: AVAudioFile
    private var hasStarted = false

    init?(fileURL: URL) {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
        self.file = file
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
    }

    func play() {
        guard !hasStarted else { return }
        hasStarted = true
        do {
            try engine.start()
        } catch {
            return
        }
        player.scheduleFile(file, at: nil)
        player.play()
    }

    func pause() {
        player.pause()
        if engine.isRunning { engine.pause() }
    }

    func resume() {
        guard hasStarted else { return }
        do {
            try engine.start()
        } catch {
            return
        }
        player.play()
    }

    func stop() {
        player.stop()
        engine.stop()
        hasStarted = false
    }

    deinit {
        stop()
    }
}
