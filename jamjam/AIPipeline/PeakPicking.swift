import Foundation

/// Port of `ml/scripts/note_classification.py`'s `pick_peaks` — must stay logically
/// identical (same thresholds behave the same way) since this is what turns the onset
/// CNN's per-frame probabilities into discrete note events.
enum PeakPicking {
    /// Local-maximum peak-picking with non-max suppression: within each contiguous run
    /// of frames above `threshold`, keep only that run's peak frame; also enforce a
    /// minimum frame gap between consecutive picked peaks.
    static func pickPeaks(_ probs: [Float], threshold: Float = 0.5, minSeparationFrames: Int = 3) -> [Int] {
        let n = probs.count
        var rawPeaks: [Int] = []
        var i = 0
        while i < n {
            if probs[i] > threshold {
                var j = i
                var bestIdx = i
                var bestVal = probs[i]
                while j < n && probs[j] > threshold {
                    if probs[j] > bestVal { bestVal = probs[j]; bestIdx = j }
                    j += 1
                }
                rawPeaks.append(bestIdx)
                i = j
            } else {
                i += 1
            }
        }

        var peaks: [Int] = []
        for p in rawPeaks {
            if let last = peaks.last, (p - last) < minSeparationFrames {
                if probs[p] > probs[last] { peaks[peaks.count - 1] = p }
                continue
            }
            peaks.append(p)
        }
        return peaks
    }
}
