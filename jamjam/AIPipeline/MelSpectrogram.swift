import Accelerate
import Foundation

/// Swift/Accelerate log-mel spectrogram matching `ml/scripts/onset/melspec.py` exactly —
/// this must produce the same numbers the onset CNN was trained on, or its predictions
/// mean nothing on-device.
///
/// STFT part matches librosa.stft's defaults (center=True, pad_mode='constant' i.e. zero
/// padding, periodic Hann window, NO extra normalization — unlike HTDemucsSTFT's
/// torch-normalized STFT, this is the plain unnormalized DFT). The mel filterbank itself
/// is NOT re-derived here — librosa.filters.mel(sr=22050, n_fft=1024, n_mels=80,
/// fmin=27.5, fmax=8000) (Slaney-normalized triangular filters) was exported once to
/// `mel_filterbank_80x513.bin` and is just matrix-multiplied against the power
/// spectrogram, avoiding any risk of subtly mismatching librosa's mel-scale formula.
enum MelSpectrogram {
    static let sampleRate = 22050
    static let nFFT = 1024
    static let hopLength = 220
    static let nMels = 80
    static let halfN = nFFT / 2          // 512 (Nyquist bin kept — melspectrogram uses all 513 bins)
    static let freqBins = halfN + 1      // 513
    static let log2n = vDSP_Length(10)   // log2(1024)

    static let contextFrames = 15
    static let contextHalf = contextFrames / 2

    private static let fftSetup: FFTSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

    /// scipy/librosa's periodic Hann: 0.5 - 0.5*cos(2*pi*n/N), same convention as
    /// HTDemucsSTFT.analysisWindow just at a different length.
    static let analysisWindow: [Float] = {
        var w = [Float](repeating: 0, count: nFFT)
        let n = Float(nFFT)
        for i in 0..<nFFT { w[i] = 0.5 - 0.5 * cosf(2.0 * Float.pi * Float(i) / n) }
        return w
    }()

    private static var _melFilterbank: [Float]?

    enum MelError: Error, LocalizedError {
        case filterbankNotFound
        case filterbankBadSize(Int)

        var errorDescription: String? {
            switch self {
            case .filterbankNotFound: return "mel_filterbank_80x513.bin 리소스를 찾을 수 없음"
            case .filterbankBadSize(let n): return "mel filterbank 파일 크기 불일치: \(n) floats"
            }
        }
    }

    /// Loads (once) the exported librosa mel filterbank, row-major [nMels][freqBins].
    static func loadMelFilterbank() throws -> [Float] {
        if let cached = _melFilterbank { return cached }
        guard let url = Bundle.main.url(forResource: "mel_filterbank_80x513", withExtension: "bin") else {
            throw MelError.filterbankNotFound
        }
        let data = try Data(contentsOf: url)
        let count = data.count / MemoryLayout<Float>.size
        guard count == nMels * freqBins else { throw MelError.filterbankBadSize(count) }
        let fb = data.withUnsafeBytes { ptr in Array(ptr.bindMemory(to: Float.self)) }
        _melFilterbank = fb
        return fb
    }

    /// One mono channel -> log-mel spectrogram, shape [nMels][frames], normalized
    /// per-utterance to zero mean / unit variance (matching melspec.py's compute_log_mel).
    static func computeLogMel(_ y: [Float]) throws -> [[Float]] {
        let melFilterbank = try loadMelFilterbank()

        // center=True, pad_mode='constant': zero-pad by nFFT/2 on both sides.
        let pad = nFFT / 2
        var padded = [Float](repeating: 0, count: y.count + 2 * pad)
        padded.withUnsafeMutableBufferPointer { dst in
            y.withUnsafeBufferPointer { src in
                (dst.baseAddress! + pad).update(from: src.baseAddress!, count: y.count)
            }
        }

        // librosa's centered-STFT frame count: 1 + floor(y.count / hop)
        let nFrames = 1 + y.count / hopLength

        var powerSpec = [[Float]](repeating: [Float](repeating: 0, count: nFrames), count: freqBins)

        var windowed = [Float](repeating: 0, count: nFFT)
        var realBuf = [Float](repeating: 0, count: halfN)
        var imagBuf = [Float](repeating: 0, count: halfN)

        for f in 0..<nFrames {
            let start = f * hopLength
            for i in 0..<nFFT {
                let sample = (start + i) < padded.count ? padded[start + i] : 0
                windowed[i] = sample * analysisWindow[i]
            }
            realBuf.withUnsafeMutableBufferPointer { realPtr in
                imagBuf.withUnsafeMutableBufferPointer { imagPtr in
                    var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    windowed.withUnsafeBufferPointer { wPtr in
                        wPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cPtr in
                            vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(halfN))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            // vDSP forward zrip result is 2x the standard DFT (see HTDemucsSTFT for the
            // same well-documented convention) — power = |X|^2, so the missing /2 factor
            // becomes /4 once squared.
            let scale: Float = 1.0 / 4.0
            // bin 0 (DC) and bin halfN (Nyquist) are both real-valued, packed specially.
            powerSpec[0][f] = (realBuf[0] * realBuf[0]) * scale
            powerSpec[halfN][f] = (imagBuf[0] * imagBuf[0]) * scale
            for k in 1..<halfN {
                powerSpec[k][f] = (realBuf[k] * realBuf[k] + imagBuf[k] * imagBuf[k]) * scale
            }
        }

        // mel = filterbank [nMels x freqBins] @ powerSpec [freqBins x nFrames]
        var melEnergies = [[Float]](repeating: [Float](repeating: 0, count: nFrames), count: nMels)
        for m in 0..<nMels {
            let rowBase = m * freqBins
            for k in 0..<freqBins {
                let weight = melFilterbank[rowBase + k]
                if weight == 0 { continue }
                let row = powerSpec[k]
                for t in 0..<nFrames { melEnergies[m][t] += weight * row[t] }
            }
        }

        // power_to_db(mel, ref=max): 10*log10(x) - 10*log10(max), floored at -80dB below max
        // (librosa's default top_db=80).
        var maxVal: Float = 1e-10
        for row in melEnergies { for v in row { maxVal = max(maxVal, v) } }
        let logRef = 10 * log10f(max(maxVal, 1e-10))

        var logMel = [[Float]](repeating: [Float](repeating: 0, count: nFrames), count: nMels)
        var sum: Double = 0
        var sumSq: Double = 0
        let total = Double(nMels * nFrames)
        for m in 0..<nMels {
            for t in 0..<nFrames {
                let v = 10 * log10f(max(melEnergies[m][t], 1e-10)) - logRef
                let clamped = max(v, -80)
                logMel[m][t] = clamped
                sum += Double(clamped)
                sumSq += Double(clamped) * Double(clamped)
            }
        }

        // per-file normalize to zero mean / unit variance (matches melspec.py exactly)
        let mean = Float(sum / total)
        let variance = Float(sumSq / total) - mean * mean
        let std = sqrtf(max(variance, 0))
        let denom = std + 1e-6
        for m in 0..<nMels {
            for t in 0..<nFrames { logMel[m][t] = (logMel[m][t] - mean) / denom }
        }

        return logMel
    }

    /// Extracts a `contextFrames`-wide window centered on each of `centerFrames`,
    /// edge-padding at the boundaries (matches melspec.py's extract_windows).
    static func extractWindows(_ logMel: [[Float]], centerFrames: [Int]) -> [Float] {
        let nMelsLocal = logMel.count
        let nFrames = logMel[0].count
        var padded = [[Float]](repeating: [Float](repeating: 0, count: nFrames + 2 * contextHalf), count: nMelsLocal)
        for m in 0..<nMelsLocal {
            for t in 0..<nFrames { padded[m][t + contextHalf] = logMel[m][t] }
            for t in 0..<contextHalf {
                padded[m][t] = logMel[m][0]
                padded[m][nFrames + contextHalf + t] = logMel[m][nFrames - 1]
            }
        }

        var flat = [Float](repeating: 0, count: centerFrames.count * nMelsLocal * contextFrames)
        var idx = 0
        for c in centerFrames {
            for m in 0..<nMelsLocal {
                for t in 0..<contextFrames {
                    flat[idx] = padded[m][c + t]
                    idx += 1
                }
            }
        }
        return flat
    }
}
