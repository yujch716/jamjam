import AVFoundation
import Foundation

/// Decodes any AVFoundation-readable audio file (mp3 included) to planar Float32 PCM at
/// an arbitrary target sample rate/channel count, using AVAudioConverter for whatever
/// resampling/channel conversion is needed — so the rest of the pipeline never has to
/// care what format the original file was in.
enum AudioFileLoader {
    enum LoaderError: Error, LocalizedError {
        case formatCreationFailed
        case converterCreationFailed
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .formatCreationFailed: return "오디오 포맷 생성 실패"
            case .converterCreationFailed: return "오디오 컨버터 생성 실패"
            case .conversionFailed(let msg): return "오디오 변환 실패: \(msg)"
            }
        }
    }

    /// Returns planar channels [C][sample] at `targetSampleRate`/`targetChannels`.
    static func load(url: URL, targetSampleRate: Double, targetChannels: Int) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate,
            channels: AVAudioChannelCount(targetChannels), interleaved: false
        ) else { throw LoaderError.formatCreationFailed }

        if file.processingFormat.sampleRate == targetSampleRate,
           file.processingFormat.channelCount == AVAudioChannelCount(targetChannels) {
            return try readAllPlanar(file: file, format: file.processingFormat)
        }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw LoaderError.converterCreationFailed
        }

        let estimatedOutFrames = AVAudioFrameCount(
            Double(file.length) * targetSampleRate / file.processingFormat.sampleRate
        ) + 4096
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedOutFrames) else {
            throw LoaderError.formatCreationFailed
        }

        var readError: Error?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            let chunkSize: AVAudioFrameCount = 65536
            guard let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkSize) else {
                outStatus.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: chunk, frameCount: chunkSize)
            } catch {
                readError = error
                outStatus.pointee = .endOfStream
                return nil
            }
            if chunk.frameLength == 0 {
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return chunk
        }

        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)
        if let readError { throw readError }
        if status == .error, let conversionError { throw conversionError }

        return planarChannels(from: outputBuffer, channels: targetChannels)
    }

    private static func readAllPlanar(file: AVAudioFile, format: AVAudioFormat) throws -> [[Float]] {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw LoaderError.formatCreationFailed
        }
        try file.read(into: buffer)
        return planarChannels(from: buffer, channels: Int(format.channelCount))
    }

    private static func planarChannels(from buffer: AVAudioPCMBuffer, channels: Int) -> [[Float]] {
        guard let data = buffer.floatChannelData else { return [] }
        let n = Int(buffer.frameLength)
        var result = [[Float]]()
        for c in 0..<channels {
            result.append(Array(UnsafeBufferPointer(start: data[c], count: n)))
        }
        return result
    }

    /// Averages a multi-channel signal down to mono (matches numpy's `.mean(axis=0)`,
    /// not AVAudioConverter's own downmix algorithm, so it's predictable/reproducible).
    static func toMono(_ channels: [[Float]]) -> [Float] {
        guard channels.count > 1 else { return channels.first ?? [] }
        let n = channels[0].count
        var mono = [Float](repeating: 0, count: n)
        for ch in channels {
            for i in 0..<n { mono[i] += ch[i] }
        }
        let scale = 1.0 / Float(channels.count)
        for i in 0..<n { mono[i] *= scale }
        return mono
    }

    /// Resamples a single mono channel to a new sample rate via AVAudioConverter.
    static func resample(_ mono: [Float], from sourceSampleRate: Double, to targetSampleRate: Double) throws -> [Float] {
        guard sourceSampleRate != targetSampleRate else { return mono }
        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceSampleRate, channels: 1, interleaved: false),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false) else {
            throw LoaderError.formatCreationFailed
        }
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(mono.count)) else {
            throw LoaderError.formatCreationFailed
        }
        inputBuffer.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { src in
            inputBuffer.floatChannelData![0].update(from: src.baseAddress!, count: mono.count)
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw LoaderError.converterCreationFailed
        }
        let outFrames = AVAudioFrameCount(Double(mono.count) * targetSampleRate / sourceSampleRate) + 4096
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else {
            throw LoaderError.formatCreationFailed
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if consumed { outStatus.pointee = .endOfStream; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if status == .error, let conversionError { throw conversionError }

        return Array(UnsafeBufferPointer(start: outputBuffer.floatChannelData![0], count: Int(outputBuffer.frameLength)))
    }

    /// Writes planar audio as a float32 WAV file.
    static func writeWav(_ channels: [[Float]], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                          channels: AVAudioChannelCount(channels.count), interleaved: false) else {
            throw LoaderError.formatCreationFailed
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frameCount = AVAudioFrameCount(channels[0].count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw LoaderError.formatCreationFailed
        }
        buffer.frameLength = frameCount
        for c in 0..<channels.count {
            channels[c].withUnsafeBufferPointer { src in
                buffer.floatChannelData![c].update(from: src.baseAddress!, count: channels[c].count)
            }
        }
        try file.write(from: buffer)
    }
}
