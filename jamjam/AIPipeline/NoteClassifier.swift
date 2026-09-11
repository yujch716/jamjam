import Accelerate
import Foundation

/// Port of `ml/scripts/note_classification.py`: RMS-envelope tap/hold classification
/// plus the track-relative energy gate that suppresses onset false-positives in
/// near-silent stretches (see full_pipeline.py's "energy pre-filter" — applied
/// uniformly to all instruments, not just piano).
enum NoteClassifier {
    /// librosa.feature.rms(frame_length=2048, hop_length:, center=True, pad_mode='constant'):
    /// RMS over a `frameLength`-sample window centered at each hop position, i.e. the
    /// window for output frame f covers padded-signal samples
    /// [f*hop, f*hop+frameLength) where the signal was zero-padded by frameLength/2 on
    /// both sides first. Frame count matches `librosa.feature.rms`'s: 1 + y.count/hop
    /// (same centered-STFT-style formula as MelSpectrogram's frame count, since both
    /// use center=True framing at the same hop).
    static func computeRMS(_ y: [Float], frameLength: Int = 2048, hopLength: Int) -> [Float] {
        let pad = frameLength / 2
        var padded = [Float](repeating: 0, count: y.count + 2 * pad)
        padded.withUnsafeMutableBufferPointer { dst in
            y.withUnsafeBufferPointer { src in
                (dst.baseAddress! + pad).update(from: src.baseAddress!, count: y.count)
            }
        }
        let nFrames = 1 + y.count / hopLength
        var rms = [Float](repeating: 0, count: nFrames)
        padded.withUnsafeBufferPointer { buf in
            for f in 0..<nFrames {
                let start = f * hopLength
                var sumSq: Float = 0
                vDSP_svesq(buf.baseAddress! + start, 1, &sumSq, vDSP_Length(frameLength))
                rms[f] = sqrtf(sumSq / Float(frameLength))
            }
        }
        return rms
    }

    /// Frame-aligned boolean mask, true where the frame is "silent" relative to this
    /// track's OWN peak RMS (below `peakRatio` of it) — see full_pipeline.py's
    /// SILENCE_PEAK_RATIO (4%) for why this must be track-relative, not a fixed dB level.
    static func computeSilenceMask(_ y: [Float], hopLength: Int, nFrames: Int, peakRatio: Float = 0.04) -> [Bool] {
        var rms = computeRMS(y, hopLength: hopLength)
        if rms.count < nFrames {
            rms += [Float](repeating: rms.last ?? 0, count: nFrames - rms.count)
        } else if rms.count > nFrames {
            rms = Array(rms[0..<nFrames])
        }
        let threshold = (rms.max() ?? 0) * peakRatio
        return rms.map { $0 < threshold }
    }

    /// A classified note before lane assignment — `intensity` (the local RMS peak used to
    /// decide tap/hold) doubles as an onset-strength proxy for `LaneAssigner`'s simultaneous
    /// 2-note promotion, matching `note_classification.py`'s `_intensity` field.
    struct RawClassifiedNote {
        let time: Double
        let type: NoteType
        let duration: Double?
        let intensity: Float
    }

    /// For each onset time, measures how long the RMS envelope stays above a
    /// per-note-relative threshold (a fraction of that note's own peak level shortly
    /// after onset) to decide tap vs. hold, with hold `duration` capped at whichever
    /// comes first: the envelope decaying, or the next onset starting.
    static func classifyNotes(
        y: [Float], sampleRate: Int, onsetTimes: [Double], hopLength: Int,
        holdMinDuration: Double = 0.2, sustainRatio: Float = 0.2, frameLength: Int = 2048
    ) -> [RawClassifiedNote] {
        let rms = computeRMS(y, frameLength: frameLength, hopLength: hopLength)
        let nFrames = rms.count
        let frameRate = Double(sampleRate) / Double(hopLength)
        let peakSearchFrames = max(1, Int(0.05 * frameRate))

        var notes: [RawClassifiedNote] = []
        for (idx, t) in onsetTimes.enumerated() {
            let onsetFrame = Int((t * frameRate).rounded())
            if onsetFrame >= nFrames { continue }
            let nextOnsetFrame = idx + 1 < onsetTimes.count
                ? Int((onsetTimes[idx + 1] * frameRate).rounded())
                : nFrames

            let searchEnd = min(nFrames, onsetFrame + peakSearchFrames)
            var localPeak: Float = 0
            for f in onsetFrame..<max(onsetFrame + 1, searchEnd) where f < nFrames { localPeak = max(localPeak, rms[f]) }
            let threshold = localPeak * sustainRatio

            var f = onsetFrame
            let limit = min(nFrames, nextOnsetFrame)
            while f < limit && rms[f] > threshold { f += 1 }
            let sustainSeconds = Double(f - onsetFrame) / frameRate

            if sustainSeconds < holdMinDuration {
                notes.append(RawClassifiedNote(time: t, type: .tap, duration: nil, intensity: localPeak))
            } else {
                let endFrame = min(f, nextOnsetFrame)
                let duration = Double(endFrame - onsetFrame) / frameRate
                notes.append(RawClassifiedNote(time: t, type: .hold, duration: duration, intensity: localPeak))
            }
        }
        return notes
    }
}
