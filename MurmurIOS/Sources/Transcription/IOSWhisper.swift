import Foundation
import AVFoundation
import MurmurCore
import whisper

enum IOSWhisperError: LocalizedError {
    case modelMissing
    case initFailed
    case transcriptionFailed
    case invalidAudio

    var errorDescription: String? {
        switch self {
        case .modelMissing: return "Whisper model is not downloaded yet."
        case .initFailed: return "Failed to load the on-device Whisper model."
        case .transcriptionFailed: return "On-device transcription failed."
        case .invalidAudio: return "Could not decode recorded audio."
        }
    }
}

/// Thin Swift wrapper around the whisper.cpp XCFramework for iOS.
/// Loads a ggml model and transcribes 16 kHz mono PCM float samples. Metal on device; CPU on Simulator.
final class IOSWhisper: @unchecked Sendable {
    static let shared = IOSWhisper()

    private var context: OpaquePointer?
    private var loadedModelPath: String?
    private let lock = NSLock()

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
                    let text = try self.runWhisper(samples: samples, language: langCode)
                    cont.resume(returning: text)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

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

    private func runWhisper(samples: [Float], language: String) throws -> String {
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

        let text: String = language.withCString { langPtr in
            params.language = langPtr
            params.detect_language = (language == "auto")

            let result = samples.withUnsafeBufferPointer { buf -> Int32 in
                guard let base = buf.baseAddress else { return -1 }
                return whisper_full(context, params, base, Int32(buf.count))
            }
            guard result == 0 else { return "" }

            var transcription = ""
            let n = whisper_full_n_segments(context)
            for i in 0..<n {
                if let cStr = whisper_full_get_segment_text(context, i) {
                    transcription += String(cString: cStr)
                }
            }
            return transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if text.isEmpty { throw IOSWhisperError.transcriptionFailed }
        return text
    }

    /// Decode recorded audio into 16 kHz mono Float32 PCM for whisper.cpp.
    static func pcmFloat32Mono16kHz(from data: Data) throws -> [Float] {
        try decodeWithAVAudio(data)
    }

    private static func decodeWithAVAudio(_ data: Data) throws -> [Float] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".audio")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = try AVAudioFile(forReading: tmp)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw IOSWhisperError.invalidAudio
        }
        try file.read(into: buffer)

        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
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
        if let error { throw error }
        guard let ch = outBuffer.floatChannelData?[0] else { throw IOSWhisperError.invalidAudio }
        return Array(UnsafeBufferPointer(start: ch, count: Int(outBuffer.frameLength)))
    }
}
