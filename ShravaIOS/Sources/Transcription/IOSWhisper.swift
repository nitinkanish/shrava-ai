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

private struct WhisperPassResult {
    var text: String
    var language: SupportedLanguage
    var averageLogProb: Double
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

        let resolved = try detectOrResolveLanguage(samples: samples, requested: language)
        let pass = try await transcribeSamplesWithRetries(
            samples: samples,
            durationSeconds: durationSeconds,
            language: resolved,
            allowEmpty: false
        )
        return try await finalize(original: pass.text, language: pass.language, durationSeconds: durationSeconds, dictionary: dictionary)
    }

    /// Prefer a single whole-file whisper pass (better language consistency). Fall back to ~30s chunks.
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

        // Decode full file once for language detect + whole-pass attempt.
        let allSamples: [Float]
        do {
            allSamples = try Self.pcmFloat32Mono16kHz(fromFile: url)
        } catch {
            WhisperChunkLog.chunkLog.error("whole-file decode failed: \(error.localizedDescription, privacy: .public) — chunk fallback")
            return try await transcribeFileChunked(
                url: url,
                durationSeconds: durationSeconds,
                language: language,
                dictionary: dictionary,
                progress: progress,
                partialText: partialText
            )
        }
        guard !allSamples.isEmpty else { throw IOSWhisperError.invalidAudio }

        let resolved = try detectOrResolveLanguage(samples: allSamples, requested: language)
        await progress(0.05)

        // Whole-audio one-pass (whisper.cpp windows internally). Skip for extremely long files to avoid OOM.
        let maxWholePassSamples = 16_000 * 60 * 45 // ~45 min @ 16 kHz
        if allSamples.count <= maxWholePassSamples {
            do {
                let pass = try await transcribeSamplesWithRetries(
                    samples: allSamples,
                    durationSeconds: durationSeconds,
                    language: resolved,
                    allowEmpty: false
                )
                if !WhisperLanguageSupport.needsRetry(text: pass.text, durationSeconds: durationSeconds)
                    || pass.text.count > 20 {
                    await progress(1)
                    await partialText?(pass.text)
                    WhisperChunkLog.chunkLog.info("whole-pass ok lang=\(pass.language.rawValue, privacy: .public) chars=\(pass.text.count) dur=\(durationSeconds, format: .fixed(precision: 1))")
                    Self.clearCheckpoint(for: url)
                    return try await finalize(original: pass.text, language: pass.language, durationSeconds: durationSeconds, dictionary: dictionary)
                }
                WhisperChunkLog.chunkLog.warning("whole-pass weak (\(pass.text.count) chars) — falling back to chunks")
            } catch {
                WhisperChunkLog.chunkLog.error("whole-pass failed: \(error.localizedDescription, privacy: .public) — chunk fallback")
            }
        }

        return try await transcribeFileChunked(
            url: url,
            durationSeconds: durationSeconds,
            language: resolved, // already resolved en/hi — do not re-auto per chunk
            dictionary: dictionary,
            progress: progress,
            partialText: partialText
        )
    }

    // MARK: - Language detect (en / hi)

    /// Detect language from the first ~30s. Restricted to English/Hindi; mixed → Hindi.
    private func detectOrResolveLanguage(samples: [Float], requested: SupportedLanguage) throws -> SupportedLanguage {
        guard requested == .auto else { return requested }
        let probeCount = min(samples.count, 16_000 * 30)
        guard probeCount > 16_000 else { return .hindi }
        let probe = Array(samples.prefix(probeCount))

        lock.lock()
        defer { lock.unlock() }
        guard let context else { throw IOSWhisperError.modelMissing }

        let threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        let mel = probe.withUnsafeBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return whisper_pcm_to_mel(context, base, Int32(buf.count), threads)
        }
        guard mel == 0 else {
            WhisperChunkLog.chunkLog.warning("pcm_to_mel failed for language detect — defaulting to hi")
            return .hindi
        }

        let maxId = Int(whisper_lang_max_id())
        var probs = [Float](repeating: 0, count: maxId + 1)
        let topId = probs.withUnsafeMutableBufferPointer { buf -> Int32 in
            whisper_lang_auto_detect(context, 0, threads, buf.baseAddress)
        }
        let enId = Int(whisper_lang_id("en"))
        let hiId = Int(whisper_lang_id("hi"))
        let enP = (enId >= 0 && enId <= maxId) ? Double(probs[enId]) : 0
        let hiP = (hiId >= 0 && hiId <= maxId) ? Double(probs[hiId]) : 0
        var detectedCode: String? = nil
        if topId >= 0, let cStr = whisper_lang_str(topId) {
            detectedCode = String(cString: cStr)
        }
        let resolved = WhisperLanguageSupport.resolveAuto(
            detectedCode: detectedCode,
            enProbability: enP,
            hiProbability: hiP
        )
        WhisperChunkLog.chunkLog.info("lang-detect top=\(detectedCode ?? "?", privacy: .public) en=\(enP, format: .fixed(precision: 3)) hi=\(hiP, format: .fixed(precision: 3)) -> \(resolved.rawValue, privacy: .public)")
        return resolved
    }

    // MARK: - Core whisper run

    private func transcribeSamplesWithRetries(
        samples: [Float],
        durationSeconds: Double,
        language: SupportedLanguage,
        allowEmpty: Bool
    ) async throws -> WhisperPassResult {
        var primary = try await runWhisperPass(samples: samples, language: language, allowEmpty: allowEmpty)
        if !WhisperLanguageSupport.needsRetry(text: primary.text, durationSeconds: durationSeconds) {
            return primary
        }

        let alternate = WhisperLanguageSupport.otherAutoLanguage(than: language)
        WhisperChunkLog.chunkLog.warning("retry language \(language.rawValue, privacy: .public) -> \(alternate.rawValue, privacy: .public) chars=\(primary.text.count)")
        let secondary = try await runWhisperPass(samples: samples, language: alternate, allowEmpty: allowEmpty)
        if secondary.averageLogProb > primary.averageLogProb || secondary.text.count > primary.text.count
            || !WhisperLanguageSupport.needsRetry(text: secondary.text, durationSeconds: durationSeconds) {
            primary = secondary
        }

        // Optional larger model (small) if already downloaded.
        if WhisperLanguageSupport.needsRetry(text: primary.text, durationSeconds: durationSeconds) {
            if let larger = await MainActor.run(body: { WhisperModelManager.shared.largerModelURLIfAvailable() }) {
                WhisperChunkLog.chunkLog.warning("retry larger model \(larger.lastPathComponent, privacy: .public)")
                try ensureLoaded(modelURL: larger)
                let third = try await runWhisperPass(samples: samples, language: primary.language, allowEmpty: allowEmpty)
                if third.text.count > primary.text.count
                    || !WhisperLanguageSupport.needsRetry(text: third.text, durationSeconds: durationSeconds) {
                    primary = third
                }
                // Reload default base for subsequent work.
                let base = await MainActor.run { WhisperModelManager.shared.modelURL }
                try? ensureLoaded(modelURL: base)
            }
        }
        return primary
    }

    private func runWhisperPass(samples: [Float], language: SupportedLanguage, allowEmpty: Bool) async throws -> WhisperPassResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.runWhisper(samples: samples, language: language.rawValue, allowEmpty: allowEmpty)
                    cont.resume(returning: WhisperPassResult(text: result.text, language: language, averageLogProb: result.avgLogProb))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Run whisper on samples. Empty output is allowed when `allowEmpty` (per-chunk) so silence
    /// does not abort a multi-chunk file.
    private func runWhisper(samples: [Float], language: String, allowEmpty: Bool) throws -> (text: String, avgLogProb: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard let context else { throw IOSWhisperError.modelMissing }

        let maxThreads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false // task = transcribe
        params.n_threads = Int32(maxThreads)
        params.offset_ms = 0
        params.no_context = true
        params.single_segment = false
        params.no_timestamps = true
        params.suppress_nst = true

        let pair: (String, Double) = try language.withCString { langPtr in
            params.language = langPtr
            params.detect_language = false // always set explicitly after our en/hi detect

            let result = samples.withUnsafeBufferPointer { buf -> Int32 in
                guard let base = buf.baseAddress else { return -1 }
                return whisper_full(context, params, base, Int32(buf.count))
            }
            guard result == 0 else {
                throw IOSWhisperError.transcriptionFailed
            }

            var transcription = ""
            var logProbSum: Double = 0
            var tokenCount = 0
            let n = whisper_full_n_segments(context)
            for i in 0..<n {
                if let cStr = whisper_full_get_segment_text(context, i) {
                    let seg = String(cString: cStr)
                    if WhisperLanguageSupport.isPlaceholderLine(seg.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        continue
                    }
                    transcription += seg
                }
                let nTok = whisper_full_n_tokens(context, i)
                for t in 0..<nTok {
                    let p = Double(whisper_full_get_token_p(context, i, t))
                    if p > 0 {
                        logProbSum += log(p)
                        tokenCount += 1
                    }
                }
            }
            let text = WhisperLanguageSupport.filterHallucinations(
                transcription.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let avg = tokenCount > 0 ? logProbSum / Double(tokenCount) : -10
            return (text, avg)
        }

        if pair.0.isEmpty && !allowEmpty { throw IOSWhisperError.transcriptionFailed }
        return pair
    }

    // MARK: - Chunked fallback

    private func transcribeFileChunked(
        url: URL,
        durationSeconds: Double,
        language: SupportedLanguage,
        dictionary: PersonalDictionary,
        progress: @MainActor @escaping (Double) -> Void,
        partialText: (@MainActor (String) -> Void)?
    ) async throws -> TranscriptionResult {
        let langCode = language == .auto ? "hi" : language.rawValue
        let resolvedLang: SupportedLanguage = language == .auto ? .hindi : language
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
                    let pass = try await runWhisperPass(samples: samples, language: resolvedLang, allowEmpty: true)
                    chunkText = pass.text
                    // If chunk is placeholder-heavy, try the other language once.
                    if WhisperLanguageSupport.isMostlyPlaceholders(chunkText) {
                        let alt = WhisperLanguageSupport.otherAutoLanguage(than: resolvedLang)
                        let altPass = try await runWhisperPass(samples: samples, language: alt, allowEmpty: true)
                        if altPass.text.count > chunkText.count {
                            chunkText = altPass.text
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
            WhisperChunkLog.chunkLog.debug("chunk=\(chunkIndex) frames=\(advanced) samples=\(samples.count) chars=\(chunkText.count) failed=\(chunkFailed) lang=\(langCode, privacy: .public)")

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
        WhisperChunkLog.chunkLog.info("transcribeFile chunked done chunks=\(chunkIndex) dur=\(durationSeconds, format: .fixed(precision: 1)) chars=\(parts.joined(separator: " ").count) file=\(url.lastPathComponent, privacy: .public)")

        let original = WhisperLanguageSupport.filterHallucinations(
            parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if original.isEmpty {
            if let lastChunkError { throw lastChunkError }
            throw IOSWhisperError.transcriptionFailed
        }

        Self.clearCheckpoint(for: url)
        return try await finalize(original: original, language: resolvedLang, durationSeconds: durationSeconds, dictionary: dictionary)
    }

    // MARK: - PCM decode

    static func pcmFloat32Mono16kHz(from data: Data) throws -> [Float] {
        try decodeWithAVAudio(data)
    }

    static func pcmFloat32Mono16kHz(fromFile url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw IOSWhisperError.invalidAudio
        }
        try file.read(into: buffer)
        return try convertTo16kMono(buffer: buffer, format: format)
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
        return try convertTo16kMono(buffer: buffer, format: format)
    }

    private static func convertTo16kMono(buffer: AVAudioPCMBuffer, format: AVAudioFormat) throws -> [Float] {
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

    // MARK: - Checkpoint

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

    private func finalize(
        original: String,
        language: SupportedLanguage,
        durationSeconds: Double,
        dictionary: PersonalDictionary
    ) async throws -> TranscriptionResult {
        var cleaned = WhisperLanguageSupport.filterHallucinations(original)
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
