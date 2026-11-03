import Foundation
import AVFoundation
import OSLog
import ShravaCore
import whisper

enum IOSWhisperError: LocalizedError {
    case modelMissing
    case initFailed
    case transcriptionFailed
    case invalidAudio
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing: return "Whisper model is not downloaded yet."
        case .initFailed: return "Failed to load the on-device Whisper model."
        case .transcriptionFailed: return "On-device transcription failed."
        case .invalidAudio: return "Could not decode recorded audio."
        case .conversionFailed(let detail): return "Audio conversion failed: \(detail)"
        }
    }
}

/// Checkpoint so transcription can resume after kill / jetsam.
private struct TranscribeCheckpoint: Codable {
    var chunkIndex: Int
    var parts: [String]
    var framesRead: Int64
}

private enum WhisperChunkLog {
    static let chunkLog = Logger(subsystem: "com.shrava.ios", category: "whisper")
}

/// Thin Swift wrapper around the whisper.cpp XCFramework for iOS.
/// Loads a ggml model and transcribes 16 kHz mono PCM float samples. Metal on device; CPU on Simulator.
final class IOSWhisper: @unchecked Sendable {
    static let shared = IOSWhisper()

    private var context: OpaquePointer?
    private var loadedModelPath: String?
    private let lock = NSLock()
    private let maxChunkRetries = 3

    deinit {
        lock.lock()
        defer { lock.unlock() }
        if let context {
            whisper_free(context)
        }
    }

    var isModelLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return context != nil
    }

    func unload() {
        lock.lock()
        defer { lock.unlock() }
        if let context {
            whisper_free(context)
            self.context = nil
            loadedModelPath = nil
        }
    }

    func ensureLoaded(modelURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        if context != nil, loadedModelPath == modelURL.path { return }
        if let context {
            whisper_free(context)
            self.context = nil
            loadedModelPath = nil
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw IOSWhisperError.modelMissing
        }
        var params = whisper_context_default_params()
        #if targetEnvironment(simulator)
        params.use_gpu = false
        params.flash_attn = false
        #else
        params.use_gpu = true
        params.flash_attn = true
        #endif
        guard let ctx = whisper_init_from_file_with_params(modelURL.path, params) else {
            throw IOSWhisperError.initFailed
        }
        context = ctx
        loadedModelPath = modelURL.path
    }

    func transcribe(
        audioData: Data,
        durationSeconds: Double,
        language: SupportedLanguage,
        dictionary: PersonalDictionary
    ) async throws -> TranscriptionResult {
        let modelURL = await MainActor.run { WhisperModelManager.shared.modelURL }
        try ensureLoaded(modelURL: modelURL)

        let samples = try Self.pcmFloat32Mono16kHz(from: audioData)
        guard !samples.isEmpty else { throw IOSWhisperError.invalidAudio }

        let langCode = language == .auto ? "auto" : language.rawValue
        let original: String = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let text = try self.runWhisper(samples: samples, language: langCode, allowEmpty: false)
                    cont.resume(returning: text)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        return try await finalize(original: original, language: language, durationSeconds: durationSeconds, dictionary: dictionary)
    }

    /// Run whisper on samples. Empty output is allowed when `allowEmpty` (per-chunk) so silence
    /// does not abort a multi-chunk file.
    private func runWhisper(samples: [Float], language: String, allowEmpty: Bool) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let context else { throw IOSWhisperError.modelMissing }

        let maxThreads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.n_threads = Int32(maxThreads)
        params.offset_ms = 0
        params.no_context = true
        params.single_segment = false
        params.no_timestamps = true

        let text: String = try language.withCString { langPtr in
            params.language = langPtr
            params.detect_language = (language == "auto")

            let result = samples.withUnsafeBufferPointer { buf -> Int32 in
                guard let base = buf.baseAddress else { return -1 }
                return whisper_full(context, params, base, Int32(buf.count))
            }
            guard result == 0 else {
                throw IOSWhisperError.transcriptionFailed
            }

            var transcription = ""
            let n = whisper_full_n_segments(context)
            for i in 0..<n {
                if let cStr = whisper_full_get_segment_text(context, i) {
                    transcription += String(cString: cStr)
                }
            }
            return transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if text.isEmpty && !allowEmpty { throw IOSWhisperError.transcriptionFailed }
        return text
    }

    /// Decode recorded audio into 16 kHz mono Float32 PCM for whisper.cpp.
    static func pcmFloat32Mono16kHz(from data: Data) throws -> [Float] {
        try decodeWithAVAudio(data)
    }

    private static func decodeWithAVAudio(_ data: Data) throws -> [Float] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".audio")
        try data.write(to: tmp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = try AVAudioFile(forReading: tmp)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw IOSWhisperError.invalidAudio
        }
        try file.read(into: buffer)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else { throw IOSWhisperError.invalidAudio }
        if format.sampleRate == 16000,
           format.channelCount == 1,
           format.commonFormat == .pcmFormatFloat32,
           let ch = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
        }

        guard let converter = AVAudioConverter(from: format, to: target) else {
            throw IOSWhisperError.invalidAudio
        }
        let ratio = 16000.0 / format.sampleRate
        let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrames) else {
            throw IOSWhisperError.invalidAudio
        }

        var error: NSError?
        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        if let error { throw IOSWhisperError.conversionFailed(error.localizedDescription) }
        guard let ch = outBuffer.floatChannelData?[0] else { throw IOSWhisperError.invalidAudio }
        return Array(UnsafeBufferPointer(start: ch, count: Int(outBuffer.frameLength)))
    }

    private static func checkpointURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("transcribe-progress.json")
    }

    private static func loadCheckpoint(for audioURL: URL) -> TranscribeCheckpoint? {
        let url = checkpointURL(for: audioURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TranscribeCheckpoint.self, from: data)
    }

    private static func saveCheckpoint(_ cp: TranscribeCheckpoint, for audioURL: URL) {
        let url = checkpointURL(for: audioURL)
        guard let data = try? JSONEncoder().encode(cp) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func clearCheckpoint(for audioURL: URL) {
        try? FileManager.default.removeItem(at: checkpointURL(for: audioURL))
    }

    /// Transcribe a long on-disk recording in ~30s PCM chunks (streamed; no whole-file load).
    /// Reuses a single whisper context, retries per chunk, checkpoints progress for resume after kill.
    /// Never fails the whole job if any chunk produced text — returns whatever was transcribed.
    func transcribeFile(
        url: URL,
        durationSeconds: Double,
        language: SupportedLanguage,
        dictionary: PersonalDictionary,
        progress: @MainActor @escaping (Double) -> Void,
        partialText: (@MainActor (String) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        let modelURL = await MainActor.run { WhisperModelManager.shared.modelURL }
        try ensureLoaded(modelURL: modelURL)

        let langCode = language == .auto ? "auto" : language.rawValue
        let chunkSeconds: Double = 30

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = file.length
        guard totalFrames > 0 else { throw IOSWhisperError.invalidAudio }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else { throw IOSWhisperError.invalidAudio }
        guard let converter = AVAudioConverter(from: format, to: target) else {
            throw IOSWhisperError.invalidAudio
        }

        let sourceChunkFrames = AVAudioFrameCount(format.sampleRate * chunkSeconds)
        var parts: [String] = []
        var framesRead: AVAudioFramePosition = 0
        var chunkIndex = 0
        var lastChunkError: Error?

        if let cp = Self.loadCheckpoint(for: url), cp.framesRead > 0, cp.framesRead < Int64(totalFrames) {
            parts = cp.parts
            framesRead = AVAudioFramePosition(cp.framesRead)
            chunkIndex = cp.chunkIndex
            file.framePosition = framesRead
            let joined = parts.joined(separator: " ")
            if !joined.isEmpty {
                await partialText?(joined)
            }
            await progress(min(0.99, Double(framesRead) / Double(totalFrames)))
        }

        while framesRead < totalFrames {
            let remaining = AVAudioFrameCount(totalFrames - framesRead)
            let readCount = min(sourceChunkFrames, remaining)
            guard let inBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readCount) else {
                throw IOSWhisperError.invalidAudio
            }
            file.framePosition = framesRead
            do {
                try file.read(into: inBuffer, frameCount: readCount)
            } catch {
                lastChunkError = error
                break
            }
            let advanced = AVAudioFramePosition(inBuffer.frameLength)
            if advanced == 0 { break }
            framesRead += advanced

            let ratio = 16000.0 / format.sampleRate
            let outFrames = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 32
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrames) else {
                lastChunkError = IOSWhisperError.invalidAudio
                continue
            }
            converter.reset()
            var nsError: NSError?
            var consumed = false
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return inBuffer
            }
            converter.convert(to: outBuffer, error: &nsError, withInputFrom: inputBlock)
            if let nsError {
                lastChunkError = IOSWhisperError.conversionFailed(
                    "NSError domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)"
                )
                chunkIndex += 1
                continue
            }
            guard let ch = outBuffer.floatChannelData?[0], outBuffer.frameLength > 0 else {
                chunkIndex += 1
                continue
            }
            let samples = Array(UnsafeBufferPointer(start: ch, count: Int(outBuffer.frameLength)))

            var chunkText = ""
            var chunkFailed = false
            for attempt in 1...maxChunkRetries {
                do {
                    chunkText = try await withCheckedThrowingContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            do {
                                let t = try self.runWhisper(samples: samples, language: langCode, allowEmpty: true)
                                cont.resume(returning: t)
                            } catch {
                                cont.resume(throwing: error)
                            }
                        }
                    }
                    chunkFailed = false
                    break
                } catch {
                    lastChunkError = error
                    chunkFailed = true
                    if attempt < maxChunkRetries {
                        try? await Task.sleep(nanoseconds: UInt64(150_000_000 * attempt))
                    }
                }
            }

            if !chunkText.isEmpty {
                parts.append(chunkText)
            } else if chunkFailed {
                // Keep going — later chunks may still succeed; partial text is saved.
            }
            WhisperChunkLog.chunkLog.debug("chunk=\(chunkIndex) frames=\(advanced) samples=\(samples.count) chars=\(chunkText.count) failed=\(chunkFailed) totalPartsChars=\(parts.joined(separator: " ").count)")

            chunkIndex += 1
            Self.saveCheckpoint(
                TranscribeCheckpoint(chunkIndex: chunkIndex, parts: parts, framesRead: Int64(framesRead)),
                for: url
            )
            let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                await partialText?(joined)
            }
            let frac = min(1.0, Double(framesRead) / Double(totalFrames))
            await progress(frac)
        }

        await progress(1)
        WhisperChunkLog.chunkLog.info("transcribeFile done chunks=\(chunkIndex) dur=\(durationSeconds, format: .fixed(precision: 1)) chars=\(parts.joined(separator: " ").count) file=\(url.lastPathComponent, privacy: .public)")

        let original = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if original.isEmpty {
            if let lastChunkError { throw lastChunkError }
            throw IOSWhisperError.transcriptionFailed
        }

        Self.clearCheckpoint(for: url)
        return try await finalize(original: original, language: language, durationSeconds: durationSeconds, dictionary: dictionary)
    }

    private func finalize(
        original: String,
        language: SupportedLanguage,
        durationSeconds: Double,
        dictionary: PersonalDictionary
    ) async throws -> TranscriptionResult {
        var cleaned = original
        if SettingsManager.shared.settings.autoCleanup {
            cleaned = TranscriptionCleanup.localCleanup(cleaned)
        }
        cleaned = await dictionary.applyCorrections(to: cleaned)

        return TranscriptionResult(
            originalText: original,
            cleanedText: cleaned,
            language: language,
            durationSeconds: durationSeconds
        )
    }
}
