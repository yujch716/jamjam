import CoreML
import Foundation

/// Orchestrates the full "mp3 in -> note_chart per instrument out" pipeline: demucs
/// separation -> per-instrument mel-spectrogram -> onset CNN -> energy gate ->
/// peak-picking -> tap/hold classification. Direct Swift port of
/// `ml/scripts/full_pipeline.py`, using the same parameters throughout.
enum ChartGenerationPipeline {
    struct Output {
        var duration: Double
        var stemAudio: [Instrument: [[Float]]]   // 44.1kHz stereo, keyed by game instrument
        var charts: [Instrument: [ChartNote]]
    }

    enum PipelineError: Error, LocalizedError {
        case modelNotFound(String)

        var errorDescription: String? {
            switch self {
            case .modelNotFound(let n): return "모델을 찾을 수 없음: \(n)"
            }
        }
    }

    /// (game Instrument, htdemucs_6s source name) — must match SourceSeparator.selectedSources.
    private static let instrumentSources: [(Instrument, String)] = [
        (.guitar, "guitar"), (.drum, "drums"), (.bass, "bass"), (.piano, "piano"),
    ]

    private static let onsetThreshold: Float = 0.5
    private static let peakMinSeparationSeconds: Double = 0.05

    static func loadModel(named name: String) throws -> MLModel {
        let modelURL: URL
        if let compiled = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
            modelURL = compiled
        } else if let raw = Bundle.main.url(forResource: name, withExtension: "mlpackage") {
            modelURL = try MLModel.compileModel(at: raw)
        } else {
            throw PipelineError.modelNotFound(name)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        return try MLModel(contentsOf: modelURL, configuration: config)
    }

    /// `progress` is called with a short status string and a 0...1 fraction, always on
    /// the calling (background) thread — the caller is responsible for hopping to main
    /// if it's driving UI directly.
    static func generateChart(mp3URL: URL, progress: @escaping (String, Double) -> Void) throws -> Output {
        progress("오디오 불러오는 중", 0.0)
        let stereo44k = try AudioFileLoader.load(url: mp3URL, targetSampleRate: 44100, targetChannels: 2)
        let duration = Double(stereo44k[0].count) / 44100.0

        progress("AI 모델 불러오는 중", 0.02)
        let demucsModel = try loadModel(named: "htdemucs_6s_core")
        let onsetModel = try loadModel(named: "onset_cnn")

        progress("음원 분리 중", 0.05)
        let stems = try SourceSeparator.separate(mix: stereo44k, model: demucsModel) { done, total in
            let fraction = 0.05 + 0.70 * (Double(done) / Double(total))
            progress("음원 분리 중 (\(done)/\(total))", fraction)
        }

        var stemAudio: [Instrument: [[Float]]] = [:]
        var charts: [Instrument: [ChartNote]] = [:]

        for (index, (instrument, sourceName)) in instrumentSources.enumerated() {
            let baseFraction = 0.75 + 0.24 * (Double(index) / Double(instrumentSources.count))
            progress("\(instrument.displayName) 채보 생성 중", baseFraction)

            guard let stereoStem = stems[sourceName] else { continue }
            stemAudio[instrument] = stereoStem

            let mono44k = AudioFileLoader.toMono(stereoStem)
            let mono22k = try AudioFileLoader.resample(mono44k, from: 44100, to: Double(MelSpectrogram.sampleRate))

            let (rawProbs, logMel) = try OnsetDetector.detectFrameProbabilities(y: mono22k, model: onsetModel)
            let nFrames = logMel[0].count
            let silenceMask = NoteClassifier.computeSilenceMask(mono22k, hopLength: MelSpectrogram.hopLength, nFrames: nFrames)

            var probs = rawProbs
            for i in 0..<min(probs.count, silenceMask.count) where silenceMask[i] { probs[i] = 0 }

            let frameRate = Double(MelSpectrogram.sampleRate) / Double(MelSpectrogram.hopLength)
            let minSepFrames = max(1, Int(peakMinSeparationSeconds * frameRate))
            let peakFrames = PeakPicking.pickPeaks(probs, threshold: onsetThreshold, minSeparationFrames: minSepFrames)
            let onsetTimes = peakFrames.map { Double($0) / frameRate }

            let notes = NoteClassifier.classifyNotes(
                y: mono22k, sampleRate: MelSpectrogram.sampleRate, onsetTimes: onsetTimes,
                hopLength: MelSpectrogram.hopLength
            )
            charts[instrument] = notes
        }

        progress("완료", 1.0)
        return Output(duration: duration, stemAudio: stemAudio, charts: charts)
    }
}
