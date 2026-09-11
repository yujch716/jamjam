import Accelerate
import CoreML
import Foundation

/// Wraps `onset_cnn.mlpackage`: mono audio (at MelSpectrogram.sampleRate) -> per-frame
/// onset probability curve. Processed through Core ML in fixed-size batches rather than
/// one call for the whole track — the model's batch dimension was converted with an
/// upper bound (8192; see ml/scripts/onset/convert_to_coreml.py's MAX_BATCH) that a full
/// song's frame count (~15,900 for a 2:39 song, more for longer ones) exceeds, and even
/// setting that bound higher would just trade one hardcoded ceiling for another —
/// batching keeps memory bounded regardless of song length instead.
enum OnsetDetector {
    static let batchSize = 4096

    enum DetectorError: Error, LocalizedError {
        case outputMissing(String)

        var errorDescription: String? {
            switch self {
            case .outputMissing(let n): return "onset CNN 출력 없음: \(n)"
            }
        }
    }

    static func detectFrameProbabilities(y: [Float], model: MLModel) throws -> (probs: [Float], logMel: [[Float]]) {
        let logMel = try MelSpectrogram.computeLogMel(y)
        let nFrames = logMel[0].count

        var probs = [Float](repeating: 0, count: nFrames)
        var batchStart = 0
        while batchStart < nFrames {
            try autoreleasepool {
                let batchEnd = min(nFrames, batchStart + batchSize)
                let centers = Array(batchStart..<batchEnd)
                let flat = MelSpectrogram.extractWindows(logMel, centerFrames: centers)

                let input = try MLMultiArray(
                    shape: [NSNumber(value: centers.count), NSNumber(value: MelSpectrogram.nMels), NSNumber(value: MelSpectrogram.contextFrames)],
                    dataType: .float32
                )
                let ptr = input.dataPointer.bindMemory(to: Float.self, capacity: input.count)
                flat.withUnsafeBufferPointer { src in ptr.update(from: src.baseAddress!, count: flat.count) }

                let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mel_window": input]))
                guard let probsArray = output.featureValue(for: "onset_probability")?.multiArrayValue else {
                    throw DetectorError.outputMissing("onset_probability")
                }
                let probsPtr = probsArray.dataPointer.bindMemory(to: Float.self, capacity: probsArray.count)
                for i in 0..<centers.count { probs[batchStart + i] = probsPtr[i] }

                batchStart = batchEnd
            }
        }
        return (probs, logMel)
    }
}
