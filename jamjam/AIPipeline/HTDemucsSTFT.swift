import Accelerate
import Foundation

/// Swift/Accelerate (vDSP) reimplementation of htdemucs_6s's STFT/ISTFT, matching
/// `demucs/spec.py` (spectro/ispectro) and `HTDemucs._spec`/`_ispec` exactly.
/// See `/ml/README.md` "STFT/ISTFT parameters" and `/ml/scripts/htdemucs_split.py`
/// for the Python reference this must reproduce (values, not just shapes).
///
/// vDSP's packed real-FFT convention (`vDSP_ctoz` + `vDSP_fft_zrip`) returns values that
/// are exactly 2x a standard (unnormalized) DFT, with the DC and Nyquist bins packed into
/// `realp[0]`/`imagp[0]` respectively. `normScale` below undoes that 2x factor and then
/// applies torch's `normalized=True` STFT scaling (`1/sqrt(win_length)`).
enum HTDemucsSTFT {
    static let nFFT = 4096
    static let hopLength = 1024
    static let halfN = nFFT / 2          // 2048 — frequency bins kept (Nyquist bin dropped)
    static let log2n = vDSP_Length(12)   // log2(4096)

    private static let fftSetup: FFTSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

    /// torch.hann_window(4096) with the default `periodic=True` — i.e. `0.5 - 0.5*cos(2*pi*n/N)`
    /// with denominator N (NOT N-1, which would be the symmetric variant).
    static let analysisWindow: [Float] = {
        var w = [Float](repeating: 0, count: nFFT)
        let n = Float(nFFT)
        for i in 0..<nFFT {
            w[i] = 0.5 - 0.5 * cosf(2.0 * Float.pi * Float(i) / n)
        }
        return w
    }()

    /// Matches numpy/torch "reflect" padding: mirrors samples adjacent to the edge,
    /// excluding the edge sample itself (e.g. pad([1,2,3,4,5], left:3) -> [4,3,2,1,2,3,4,5]).
    static func reflectPad(_ x: [Float], left: Int, right: Int) -> [Float] {
        precondition(left < x.count && right < x.count, "reflect pad width must be < signal length")
        var out = [Float](repeating: 0, count: left + x.count + right)
        for i in 0..<left { out[i] = x[left - i] }
        out.withUnsafeMutableBufferPointer { dst in
            x.withUnsafeBufferPointer { src in
                (dst.baseAddress! + left).update(from: src.baseAddress!, count: x.count)
            }
        }
        for i in 0..<right { out[left + x.count + i] = x[x.count - 2 - i] }
        return out
    }

    /// HTDemucs._spec: one real audio channel -> (real, imag) spectrogram, each
    /// shape [halfN=2048][frames=le]. `le = ceil(channel.count / hopLength)`.
    static func spec(_ channel: [Float]) -> (real: [[Float]], imag: [[Float]]) {
        let originalLength = channel.count
        let le = Int(ceil(Double(originalLength) / Double(hopLength)))
        let leftPad1 = hopLength / 2 * 3                              // 1536, constant
        let rightPad1 = leftPad1 + le * hopLength - originalLength    // NOT symmetric in general
        let stage1 = reflectPad(channel, left: leftPad1, right: rightPad1)   // length M
        let stage2 = reflectPad(stage1, left: halfN, right: halfN)          // torch's internal center=True pad

        let numFramesRaw = 1 + (stage2.count - nFFT) / hopLength
        precondition(numFramesRaw == le + 4, "frame count mismatch: \(numFramesRaw) vs \(le + 4)")

        // undo vDSP's 2x forward-FFT scaling, then apply torch normalized=True's 1/sqrt(win_length)
        let normScale = Float(1.0 / (2.0 * Double(nFFT).squareRoot()))

        var realFrames = [[Float]](repeating: [Float](repeating: 0, count: numFramesRaw), count: halfN)
        var imagFrames = [[Float]](repeating: [Float](repeating: 0, count: numFramesRaw), count: halfN)

        var windowed = [Float](repeating: 0, count: nFFT)
        var realBuf = [Float](repeating: 0, count: halfN)
        var imagBuf = [Float](repeating: 0, count: halfN)

        for f in 0..<numFramesRaw {
            let start = f * hopLength
            for i in 0..<nFFT {
                windowed[i] = stage2[start + i] * analysisWindow[i]
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
            // realBuf[0] = DC (real), imagBuf[0] = Nyquist (real) — Nyquist bin is dropped
            // entirely below (we only keep k in 0..<halfN, i.e. bins 0...2047).
            realFrames[0][f] = realBuf[0] * normScale
            imagFrames[0][f] = 0
            for k in 1..<halfN {
                realFrames[k][f] = realBuf[k] * normScale
                imagFrames[k][f] = imagBuf[k] * normScale
            }
        }

        // crop to the central `le` frames (drop 2 edge frames on each side)
        var croppedReal = [[Float]](repeating: [Float](repeating: 0, count: le), count: halfN)
        var croppedImag = [[Float]](repeating: [Float](repeating: 0, count: le), count: halfN)
        for k in 0..<halfN {
            for t in 0..<le {
                croppedReal[k][t] = realFrames[k][t + 2]
                croppedImag[k][t] = imagFrames[k][t + 2]
            }
        }
        return (real: croppedReal, imag: croppedImag)
    }

    /// HTDemucs._ispec: (real, imag) spectrogram [halfN][frames] -> real waveform of
    /// exactly `length` samples. `real`/`imag` are the CROPPED (le-frame) spectrograms,
    /// i.e. exactly what `spec(_:)` produces / what a source's slice of the model's `m`
    /// output represents once split into real/imag.
    static func ispec(real: [[Float]], imag: [[Float]], length: Int) -> [Float] {
        let le = Int(ceil(Double(length) / Double(hopLength)))
        precondition(real[0].count == le, "frame count \(real[0].count) doesn't match expected \(le)")
        let pad = hopLength / 2 * 3                 // 1536
        let m = 2 * pad + le * hopLength             // padded-domain length (matches forward's M)
        let framesTotal = le + 4

        let olaLength = m + nFFT
        var ola = [Float](repeating: 0, count: olaLength)
        var envelope = [Float](repeating: 0, count: olaLength)

        // undo normalized=True (*sqrt(nFFT)) and vDSP's inverse-FFT scale-by-N convention;
        // see the module doc comment / README for the full derivation.
        let synthesisScale = Float(2.0 * Double(nFFT).squareRoot())

        var packedReal = [Float](repeating: 0, count: halfN)
        var packedImag = [Float](repeating: 0, count: halfN)
        var timeFrame = [Float](repeating: 0, count: nFFT)

        for f in 0..<framesTotal {
            let t = f - 2   // index into the (cropped) le-frame real/imag arrays; out of range -> zero frame
            if t >= 0 && t < le {
                for k in 0..<halfN {
                    packedReal[k] = real[k][t] * synthesisScale
                    packedImag[k] = imag[k][t] * synthesisScale
                }
            } else {
                for k in 0..<halfN {
                    packedReal[k] = 0
                    packedImag[k] = 0
                }
            }
            packedImag[0] = 0   // Nyquist bin: always zero (dropped in forward, never reconstructed)

            packedReal.withUnsafeMutableBufferPointer { realPtr in
                packedImag.withUnsafeMutableBufferPointer { imagPtr in
                    var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                    timeFrame.withUnsafeMutableBufferPointer { outPtr in
                        outPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cPtr in
                            vDSP_ztoc(&split, 1, cPtr, 2, vDSP_Length(halfN))
                        }
                    }
                }
            }

            // empirically determined via a spec()->ispec() round-trip self-test on real
            // audio (reconstructed came out exactly 2x the original with 1/nFFT here) —
            // vDSP's inverse zrip round-trip convention needs this extra 1/2 that a naive
            // "divide by N" derivation from the forward scale doesn't account for.
            let invScale = Float(1.0 / (2.0 * Double(nFFT)))
            let start = f * hopLength
            for i in 0..<nFFT {
                let sample = timeFrame[i] * invScale * analysisWindow[i]
                ola[start + i] += sample
                envelope[start + i] += analysisWindow[i] * analysisWindow[i]
            }
        }

        let epsilon: Float = 1e-11
        for i in 0..<olaLength {
            ola[i] /= max(envelope[i], epsilon)
        }

        // undo torch's internal center=True padding (halfN each side), then crop to the
        // originally requested `length` starting at `pad` (undoes _spec's outer reflect pad).
        let centerCropped = Array(ola[halfN..<(halfN + m)])
        return Array(centerCropped[pad..<(pad + length)])
    }
}
