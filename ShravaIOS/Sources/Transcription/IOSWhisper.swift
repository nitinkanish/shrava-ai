import Foundation
import Darwin
import AVFoundation
import OSLog
import ShravaCore
import whisper

enum IOSWhisperError: LocalizedError {
    case modelMissing
    case initFailed
    case engineFailed(Int32)
    case noSpeech
    case cancelled
    case timedOut
    case invalidAudio
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing: return "Download Small Q5_1 or Large v3 Turbo in Settings, then tap Regenerate transcript. Hindi/Auto cannot use Base. Your audio is saved."
        case .initFailed: return "Whisper could not load the model. In Settings, download/select Small Q5_1 for lower memory use, then Regenerate. Your audio is saved."
        case .engineFailed(let code): return "Whisper engine failed (code \(code)). Your audio is saved; open History and retry."
        case .cancelled: return "Transcription was interrupted or cancelled. Your audio is saved; tap Regenerate transcript to retry."
        case .timedOut: return "Whisper took too long on one audio window. Your audio is saved. Try Small Q5_1 in Settings, then Regenerate transcript."
        case .noSpeech: return "No clear speech was detected. Your audio is saved; try Regenerate with the spoken language selected."
        case .invalidAudio: return "Could not decode recorded audio."
        case .conversionFailed(let detail): return "Audio conversion failed: \(detail)"
        }
    }
}

/// Native callbacks use this lock, never the context lock. Cancellation is cooperative:
/// never free a context while whisper_full is still using it.
private final class WhisperRunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var deadline = Double.greatestFiniteMagnitude
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func beginPass(seconds: Double) {
        lock.lock(); deadline = ProcessInfo.processInfo.systemUptime + max(120, min(600, seconds * 10)); lock.unlock()
    }
    func finishPass() { lock.lock(); deadline = .greatestFiniteMagnitude; lock.unlock() }
    var failure: IOSWhisperError? {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return .cancelled }
        return ProcessInfo.processInfo.systemUptime > deadline ? .timedOut : nil
    }
}

private enum WhisperChunkLog {
    static let chunkLog = Logger(subsystem: "com.shrava.ios", category: "whisper")
}

private struct WhisperPassResult {
    var text: String
    var language: SupportedLanguage
    var averageLogProb: Double
}


/// Serializes Whisper runs so History regenerate / orphan resume never pile up.
private final class WhisperRunGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func tryAcquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !busy else { return false }
        busy = true
        return true
    }

    func acquire() async {
        if tryAcquire() { return }
        await withCheckedContinuation { cont in
            lock.lock()
            if busy {
                waiters.append(cont)
                lock.unlock()
            } else {
                busy = true
                lock.unlock()
                cont.resume()
            }
        }
    }

    func release() {
        lock.lock()
        if let next = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            next.resume()
        } else {
            busy = false
            lock.unlock()
        }
    }
}

/// Thin Swift wrapper around the whisper.cpp XCFramework for iOS.
/// Loads a ggml model and transcribes bounded 16 kHz mono windows on CPU, including in the background.
final class IOSWhisper: @unchecked Sendable {
    static let shared = IOSWhisper()

    private var context: OpaquePointer?
    private var loadedModelPath: String?
    private let lock = NSLock()
    /// Cap concurrent Whisper work (UI stays responsive; one decode at a time).
    private let runGate = WhisperRunGate()
    private let controlLock = NSLock()
    private var currentControl: WhisperRunControl?

    func cancelCurrentTranscription() {
        controlLock.lock(); let control = currentControl; controlLock.unlock()
        control?.cancel()
    }

    private func setControl(_ control: WhisperRunControl?) {
        controlLock.lock(); currentControl = control; controlLock.unlock()
    }


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
        // iPhone has no background GPU support. This job can be backgrounded at any time;
        // Metal otherwise returns encode failures after Stop/lock-screen suspension.
        params.use_gpu = false
        params.flash_attn = false
        guard let ctx = whisper_init_from_file_with_params(modelURL.path, params) else {
            throw IOSWhisperError.initFailed
        }
        context = ctx
        loadedModelPath = modelURL.path
    }

    private func loadModelForLanguage(_ language: SupportedLanguage) async throws {
        if language == .hindi || language == .auto {
            try await WhisperModelManager.shared.ensureHindiCapableModel()
        } else {
            // English / other: use any installed model; do not force a turbo download.
            await MainActor.run {
                if !WhisperModelManager.shared.isReady,
                   let any = WhisperModelManager.shared.bestInstalledOption(minRank: 0) {
                    WhisperModelManager.shared.select(any)
                }
            }
            let ready = await MainActor.run { WhisperModelManager.shared.isReady }
            if !ready {
                try await WhisperModelManager.shared.ensureModel()
            }
        }
        guard let url = await MainActor.run(body: {
            WhisperModelManager.shared.modelURLForTranscription(language: language)
        }) else {
            throw IOSWhisperError.modelMissing
        }
        let name = url.lastPathComponent
        WhisperChunkLog.chunkLog.info("using model \(name, privacy: .public) for lang=\(language.rawValue, privacy: .public)")
        try ensureLoaded(modelURL: url)
    }

    func transcribe(
        audioData: Data,
        durationSeconds: Double,
        language: SupportedLanguage,
        dictionary: PersonalDictionary
    ) async throws -> TranscriptionResult {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".audio")
        try audioData.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp); Self.clearCheckpoint(for: tmp) }
        return try await transcribeFile(url: tmp, durationSeconds: durationSeconds,
            language: language, dictionary: dictionary, progress: { _ in })
    }

    /// Every file uses bounded one-minute windows. Never decode a multi-hour recording
    /// into a full-rate buffer, and never submit GPU work from a background iPhone task.
    func transcribeFile(
        url: URL,
        durationSeconds: Double,
        language: SupportedLanguage,
        dictionary: PersonalDictionary,
        progress: @MainActor @escaping (Double) async -> Void,
        partialText: (@MainActor (String) async -> Void)? = nil,
        resume: Bool = false
    ) async throws -> TranscriptionResult {
        await runGate.acquire()
        defer { runGate.release() }
        try Task.checkCancellation()
        let control = WhisperRunControl()
        setControl(control)
        defer { setControl(nil); unload() } // release the large native allocation between jobs
        return try await withTaskCancellationHandler(operation: {
            if !resume { Self.clearCheckpoint(for: url) }
            try await loadModelForLanguage(language)
            if let failure = control.failure { throw failure }
            await progress(0.01)
            return try await transcribeFileChunked(url: url, durationSeconds: durationSeconds,
                language: language, dictionary: dictionary, progress: progress,
                partialText: partialText, control: control)
        }, onCancel: { control.cancel() })
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

    private func runWhisperPass(samples: [Float], language: SupportedLanguage, allowEmpty: Bool, control: WhisperRunControl) async throws -> WhisperPassResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.runWhisper(samples: samples, language: language.rawValue, allowEmpty: allowEmpty, control: control)
                    cont.resume(returning: WhisperPassResult(text: result.text, language: language, averageLogProb: result.avgLogProb))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Run whisper on samples. Empty output is allowed when `allowEmpty` (per-chunk) so silence
    /// does not abort a multi-chunk file.
    private func runWhisper(samples: [Float], language: String, allowEmpty: Bool, control: WhisperRunControl) throws -> (text: String, avgLogProb: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard let context else { throw IOSWhisperError.modelMissing }

        if let failure = control.failure { throw failure }
        control.beginPass(seconds: Double(samples.count) / 16_000)
        let maxThreads = max(1, min(4, ProcessInfo.processInfo.processorCount - 2))
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
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
        params.suppress_blank = true
        params.suppress_nst = true
        params.temperature = 0.0
        params.temperature_inc = 0.2
        params.beam_search.beam_size = 5
        params.n_max_text_ctx = 0
        params.abort_callback_user_data = Unmanaged.passUnretained(control).toOpaque()
        params.abort_callback = { opaque in
            guard let opaque else { return false }
            return Unmanaged<WhisperRunControl>.fromOpaque(opaque).takeUnretainedValue().failure != nil
        }
        params.encoder_begin_callback_user_data = params.abort_callback_user_data
        params.encoder_begin_callback = { _, _, opaque in
            guard let opaque else { return true }
            return Unmanaged<WhisperRunControl>.fromOpaque(opaque).takeUnretainedValue().failure == nil
        }

        let modelsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shrava/models", isDirectory: true)
        let vadPath = modelsDir.appendingPathComponent("ggml-silero-v5.1.2.bin").path
        let useVad = FileManager.default.fileExists(atPath: vadPath)
        let hinglishPrompt = WhisperLanguageSupport.hinglishInitialPrompt

        let pair: (String, Double) = try language.withCString { langPtr in
            try hinglishPrompt.withCString { promptPtr in
                params.language = langPtr
                params.detect_language = false
                params.initial_prompt = promptPtr
                params.carry_initial_prompt = false
                if useVad {
                    do {
                        let result = try vadPath.withCString { vadPtr -> (String, Double) in
                            params.vad = true
                            params.vad_model_path = vadPtr
                            return try self.executeWhisper(context: context, params: &params, samples: samples)
                        }
                        if !result.0.isEmpty { return result }
                    } catch {
                        if let failure = control.failure { throw failure }
                        WhisperChunkLog.chunkLog.warning("VAD pass failed; retrying same window without VAD")
                    }
                }
                params.vad = false
                params.vad_model_path = nil
                return try self.executeWhisper(context: context, params: &params, samples: samples)
            }
        }

        if let failure = control.failure { throw failure }
        control.finishPass()
        if pair.0.isEmpty && !allowEmpty {
            throw IOSWhisperError.noSpeech
        }
        return pair
    }

    private func executeWhisper(
        context: OpaquePointer,
        params: inout whisper_full_params,
        samples: [Float]
    ) throws -> (String, Double) {
        let result = samples.withUnsafeBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return whisper_full(context, params, base, Int32(buf.count))
        }
        if let opaque = params.abort_callback_user_data,
           let failure = Unmanaged<WhisperRunControl>.fromOpaque(opaque).takeUnretainedValue().failure {
            throw failure
        }
        guard result == 0 else {
            WhisperChunkLog.chunkLog.error("whisper_full failed rc=\(result) samples=\(samples.count)")
            throw IOSWhisperError.engineFailed(result)
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
                    logProbSum += Darwin.log(p)
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


    // MARK: - Chunked fallback

    private func transcribeFileChunked(
        url: URL,
        durationSeconds: Double,
        language: SupportedLanguage,
        dictionary: PersonalDictionary,
        progress: @MainActor @escaping (Double) async -> Void,
        partialText: (@MainActor (String) async -> Void)?,
        control: WhisperRunControl
    ) async throws -> TranscriptionResult {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0 else { throw IOSWhisperError.invalidAudio }
        let ranges = TranscriptChunkScheduler.overlappingFrameRanges(
            totalFrames: file.length, sampleRate: format.sampleRate,
            windowSeconds: TranscriptionRecoveryPolicy.iosWindowSeconds,
            overlapSeconds: TranscriptionRecoveryPolicy.iosOverlapSeconds)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let fingerprint = "v2|\(bytes)|\(file.length)|\(loadedModelPath ?? "")|\(language.rawValue)|60|5"
        var checkpoint = Self.loadCheckpoint(for: url)
            .flatMap { $0.canResume(fingerprint: fingerprint, windowCount: ranges.count) ? $0 : nil }
            ?? TranscriptCheckpoint(fingerprint: fingerprint)
        if !checkpoint.parts.isEmpty {
            await partialText?(TranscriptChunkScheduler.stitchChunkTexts(checkpoint.parts))
        }
        for idx in checkpoint.nextWindow..<ranges.count {
            try Task.checkCancellation()
            if let failure = control.failure { throw failure }
            let range = ranges[idx]
            // Scope AVAudio buffers to conversion; release full-rate audio before Whisper runs.
            let samples: [Float] = try autoreleasepool {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count)) else {
                    throw IOSWhisperError.invalidAudio
                }
                file.framePosition = range.start
                try file.read(into: buffer, frameCount: AVAudioFrameCount(range.count))
                guard buffer.frameLength > 0 else { throw IOSWhisperError.invalidAudio }
                return try Self.convertTo16kMono(buffer: buffer, format: format)
            }
            await progress(min(0.98, Double(idx) / Double(ranges.count)))
            let detected = try detectOrResolveLanguage(samples: samples, requested: language)
            let resolved = TranscriptionRecoveryPolicy.languageForWindow(requested: language, detected: detected)
            // Genuine digital silence is valid; do not mistake engine failure for a silent window.
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            var text = ""
            if peak > 0.0001 {
                var pass = try await runWhisperPass(samples: samples, language: resolved, allowEmpty: true, control: control)
                if language == .auto, WhisperLanguageSupport.needsRetry(text: pass.text, durationSeconds: Double(samples.count) / 16_000) {
                    let alternate = WhisperLanguageSupport.otherAutoLanguage(than: resolved)
                    let other = try await runWhisperPass(samples: samples, language: alternate, allowEmpty: true, control: control)
                    if WhisperLanguageSupport.scoreTranscript(other.text, averageLogProb: other.averageLogProb)
                        > WhisperLanguageSupport.scoreTranscript(pass.text, averageLogProb: pass.averageLogProb) { pass = other }
                }
                text = pass.text
            }
            if let failure = control.failure { throw failure }
            checkpoint.finishWindow(text: text) // never advance or drop a failed window
            try Self.saveCheckpoint(checkpoint, for: url)
            let joined = TranscriptChunkScheduler.stitchChunkTexts(checkpoint.parts)
            if !joined.isEmpty { await partialText?(joined) }
            await progress(min(0.98, Double(idx + 1) / Double(ranges.count)))
            WhisperChunkLog.chunkLog.info("window=\(idx + 1)/\(ranges.count) chars=\(text.count) language=\(resolved.rawValue, privacy: .public) backend=cpu")
        }
        let original = WhisperLanguageSupport.filterHallucinations(TranscriptChunkScheduler.stitchChunkTexts(checkpoint.parts))
        guard !original.isEmpty else { throw IOSWhisperError.noSpeech }
        let finalLanguage: SupportedLanguage = language == .auto
            ? (WhisperLanguageSupport.containsDevanagari(original) ? .hindi : .english) : language
        let result = try await finalize(original: original, language: finalLanguage,
            durationSeconds: Double(file.length) / format.sampleRate, dictionary: dictionary)
        try Task.checkCancellation()
        if let failure = control.failure { throw failure }
        Self.clearCheckpoint(for: url)
        return result // caller publishes 100% only after durable History success
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

    private static func loadCheckpoint(for audioURL: URL) -> TranscriptCheckpoint? {
        let url = checkpointURL(for: audioURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TranscriptCheckpoint.self, from: data)
    }

    private static func saveCheckpoint(_ cp: TranscriptCheckpoint, for audioURL: URL) throws {
        let url = checkpointURL(for: audioURL)
        let data = try JSONEncoder().encode(cp)
        try data.write(to: url, options: .atomic)
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

        let settings = SettingsManager.shared.settings
        if settings.enhanceTranscript, OllamaSecrets.hasAPIKey() {
            do {
                let hint = (language == .hindi || language == .auto) ? "Hindi and English" : language.displayName
                let enhanced = try await OllamaClient.shared.enhanceTranscript(cleaned, languageHint: hint)
                if !enhanced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cleaned = enhanced
                }
            } catch {
                // Best-effort polish — keep Whisper text on failure.
            }
        }

        if settings.preferRomanHinglish, OllamaSecrets.hasAPIKey(),
           WhisperLanguageSupport.containsDevanagari(cleaned) {
            do {
                let roman = try await OllamaClient.shared.transliterateToRomanHinglish(cleaned)
                if !roman.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cleaned = roman
                }
            } catch {
                // Best-effort transliteration.
            }
        }

        return TranscriptionResult(
            originalText: original,
            cleanedText: cleaned,
            language: language,
            durationSeconds: durationSeconds
        )
    }

}
