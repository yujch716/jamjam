import Accelerate
import CoreML
import Foundation

/// Full-song demucs source separation via the STFT-excluded Core ML model
/// (`htdemucs_6s_core.mlpackage`) + `HTDemucsSTFT`'s Swift/Accelerate STFT/ISTFT.
/// The Core ML model only accepts exactly one 7.8s training-length segment per call, so
/// a full song is processed in 50%-overlapping chunks and reassembled with a
/// Hann-window crossfade (COLA at 50% hop -> exact unity-gain overlap-add) — this
/// mirrors `ml/scripts/full_pipeline.py`'s `separate_full_song` exactly, since that
/// Python function is what this is a from-scratch Swift port of.
enum SourceSeparator {
    static let trainingLength = 343980   // model.segment(39/5) * samplerate(44100)
    static let sampleRate = 44100
    static let audioChannels = 2

    /// (index into htdemucs_6s's 6-source output, source name) — only the 4 the game
    /// uses; skipping "other"/"vocals" saves their ISTFT cost entirely.
    static let selectedSources: [(index: Int, name: String)] = [
        (0, "drums"), (1, "bass"), (4, "guitar"), (5, "piano"),
    ]

    enum SeparatorError: Error, LocalizedError {
        case modelOutputMissing(String)
        case unexpectedDataType(String)

        var errorDescription: String? {
            switch self {
            case .modelOutputMissing(let n): return "모델 출력 없음: \(n)"
            case .unexpectedDataType(let n): return "예상치 못한 모델 출력 타입: \(n)"
            }
        }
    }

    /// Periodic Hann window (torch.hann_window(n, periodic=True) convention — see
    /// HTDemucsSTFT.analysisWindow for the same formula at a different length).
    private static func periodicHann(_ n: Int) -> [Float] {
        var w = [Float](repeating: 0, count: n)
        let nf = Float(n)
        for i in 0..<n { w[i] = 0.5 - 0.5 * cosf(2.0 * Float.pi * Float(i) / nf) }
        return w
    }

    private static func makeMagArray(perChannel: [(real: [[Float]], imag: [[Float]])]) throws -> MLMultiArray {
        let freqBins = perChannel[0].real.count
        let frames = perChannel[0].real[0].count
        let arr = try MLMultiArray(shape: [1, NSNumber(value: audioChannels * 2), NSNumber(value: freqBins), NSNumber(value: frames)],
                                    dataType: .float32)
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: arr.count)
        var idx = 0
        for c in 0..<audioChannels {
            for k in 0..<freqBins {
                for t in 0..<frames { ptr[idx] = perChannel[c].real[k][t]; idx += 1 }
            }
            for k in 0..<freqBins {
                for t in 0..<frames { ptr[idx] = perChannel[c].imag[k][t]; idx += 1 }
            }
        }
        return arr
    }

    private static func makeMixArray(channels: [[Float]]) throws -> MLMultiArray {
        let length = channels[0].count
        let arr = try MLMultiArray(shape: [1, NSNumber(value: audioChannels), NSNumber(value: length)], dataType: .float32)
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: arr.count)
        var idx = 0
        for c in 0..<audioChannels {
            for i in 0..<length { ptr[idx] = channels[c][i]; idx += 1 }
        }
        return arr
    }

    /// mix: 2-channel audio at 44.1kHz, arbitrary length. Returns separated stems for
    /// only `selectedSources`, each as `[channel][sample]`, same length as the input.
    static func separate(
        mix: [[Float]], model: MLModel, progress: ((Int, Int) -> Void)? = nil
    ) throws -> [String: [[Float]]] {
        precondition(mix.count == audioChannels)
        let length = mix[0].count
        let hop = trainingLength / 2

        let paddedLength = length + 2 * hop
        var padded = [[Float]](repeating: [Float](repeating: 0, count: paddedLength), count: audioChannels)
        for c in 0..<audioChannels {
            padded[c].withUnsafeMutableBufferPointer { dst in
                mix[c].withUnsafeBufferPointer { src in
                    (dst.baseAddress! + hop).update(from: src.baseAddress!, count: length)
                }
            }
        }

        let nChunks = max(1, Int(ceil(Double(max(0, paddedLength - trainingLength)) / Double(hop))) + 1)
        let outLength = (nChunks - 1) * hop + trainingLength
        let window = periodicHann(trainingLength)

        // Flat, index-addressed accumulators (one per selectedSources entry x channel)
        // instead of a [String: [[Float]]] dictionary: mutating a large array reached
        // through `dict[key]![channel]` inside a hot per-sample loop risks a
        // copy-on-write duplication of the whole (multi-megabyte) buffer on every
        // access, which is exactly the kind of per-chunk memory blow-up that got this
        // killed by the OS (signal 9) partway through a real song on-device. Flat
        // `var` arrays captured directly by `withUnsafeMutableBufferPointer` have no
        // such ambiguity.
        var envelope = [Float](repeating: 0, count: outLength)
        var accumulators = [[Float]](repeating: [Float](repeating: 0, count: outLength),
                                      count: selectedSources.count * audioChannels)

        for chunkIndex in 0..<nChunks {
            // Each chunk allocates several MB of MLMultiArray/intermediate buffers;
            // without this, ARC-managed temporaries pile up in the thread's
            // autorelease pool across all 40+ chunks of a real song instead of being
            // freed as each chunk finishes, which is what triggered the OOM kill.
            try autoreleasepool {
                let start = chunkIndex * hop
                var chunk = [[Float]](repeating: [Float](repeating: 0, count: trainingLength), count: audioChannels)
                for c in 0..<audioChannels {
                    let available = min(trainingLength, paddedLength - start)
                    if available > 0 {
                        chunk[c].withUnsafeMutableBufferPointer { dst in
                            padded[c].withUnsafeBufferPointer { src in
                                dst.baseAddress!.update(from: src.baseAddress! + start, count: available)
                            }
                        }
                    }
                }

                let specs = chunk.map { HTDemucsSTFT.spec($0) }
                let magArray = try makeMagArray(perChannel: specs)
                let mixArray = try makeMixArray(channels: chunk)

                let input = try MLDictionaryFeatureProvider(dictionary: ["mag": magArray, "mix": mixArray])
                let output = try model.prediction(from: input)
                guard let mOut = output.featureValue(for: "m")?.multiArrayValue else {
                    throw SeparatorError.modelOutputMissing("m")
                }
                guard let xtOut = output.featureValue(for: "xt")?.multiArrayValue else {
                    throw SeparatorError.modelOutputMissing("xt")
                }
                guard mOut.dataType == .float32, xtOut.dataType == .float32 else {
                    throw SeparatorError.unexpectedDataType("expected float32, got m=\(mOut.dataType.rawValue) xt=\(xtOut.dataType.rawValue)")
                }

                // MLMultiArray isn't guaranteed C-contiguous — read via actual strides.
                let mPtr = mOut.dataPointer.bindMemory(to: Float.self, capacity: mOut.count)
                let xtPtr = xtOut.dataPointer.bindMemory(to: Float.self, capacity: xtOut.count)
                let freqBins = mOut.shape[3].intValue
                let frames = mOut.shape[4].intValue
                let mStrideSource = mOut.strides[1].intValue
                let mStrideChannel = mOut.strides[2].intValue
                let mStrideFreq = mOut.strides[3].intValue
                let mStrideFrame = mOut.strides[4].intValue
                let xtStrideSource = xtOut.strides[1].intValue
                let xtStrideChannel = xtOut.strides[2].intValue
                let xtStrideSample = xtOut.strides[3].intValue

                for (slot, (sourceIndex, _)) in selectedSources.enumerated() {
                    for c in 0..<audioChannels {
                        let realChanBase = sourceIndex * mStrideSource + (2 * c) * mStrideChannel
                        let imagChanBase = sourceIndex * mStrideSource + (2 * c + 1) * mStrideChannel
                        var real = [[Float]](repeating: [Float](repeating: 0, count: frames), count: freqBins)
                        var imag = [[Float]](repeating: [Float](repeating: 0, count: frames), count: freqBins)
                        for k in 0..<freqBins {
                            let realFreqBase = realChanBase + k * mStrideFreq
                            let imagFreqBase = imagChanBase + k * mStrideFreq
                            for t in 0..<frames {
                                real[k][t] = mPtr[realFreqBase + t * mStrideFrame]
                                imag[k][t] = mPtr[imagFreqBase + t * mStrideFrame]
                            }
                        }
                        let freqBranch = HTDemucsSTFT.ispec(real: real, imag: imag, length: trainingLength)
                        let xtBase = sourceIndex * xtStrideSource + c * xtStrideChannel

                        let accIndex = slot * audioChannels + c
                        accumulators[accIndex].withUnsafeMutableBufferPointer { acc in
                            for i in 0..<trainingLength {
                                let sample = (freqBranch[i] + xtPtr[xtBase + i * xtStrideSample]) * window[i]
                                acc[start + i] += sample
                            }
                        }
                    }
                }

                for i in 0..<trainingLength { envelope[start + i] += window[i] * window[i] }
                progress?(chunkIndex + 1, nChunks)
            }
        }

        let epsilon: Float = 1e-11
        var result: [String: [[Float]]] = [:]
        for (slot, (_, name)) in selectedSources.enumerated() {
            var stem = [[Float]](repeating: [Float](repeating: 0, count: length), count: audioChannels)
            for c in 0..<audioChannels {
                let accIndex = slot * audioChannels + c
                for i in 0..<length {
                    let acc = accumulators[accIndex][hop + i]
                    stem[c][i] = acc / max(envelope[hop + i], epsilon)
                }
            }
            result[name] = stem
        }
        return result
    }
}
