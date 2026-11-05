import Foundation
import Darwin
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


/// Serializes Whisper runs so History regenerate / orphan resume never pile up.
private final class WhisperRunGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        lock.lock()
        if !busy {
            busy = true
            lock.unlock()
            return
        }
        lock.unlock()
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
/// Loads a ggml model and transcribes 16 kHz mono PCM float samples. Metal on device; CPU on Simulator.
final class IOSWhisper: @unchecked Sendable {
    static let shared = IOSWhisper()

    private var context: OpaquePointer?
    private var loadedModelPath: String?
    private let lock = NSLock()
    /// Cap concurrent Whisper work (UI stays responsive; one decode at a time).
    private let runGate = WhisperRunGate()
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
        try await loadModelForLanguage(language)

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

    /// Prefer a single whole-file whisper pass for short captures. Long meetings stream
    /// overlapping 5–10 min windows (no full-PCM load) to avoid OOM / jetsam.
    func transcribeFile(
        url: URL,
        durationSeconds: Double,
        language: SupportedLanguage,
        dictionary: PersonalDictionary,
        progress: @MainActor @escaping (Double) -> Void,
        partialText: (@MainActor (String) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        await runGate.acquire()
        defer { runGate.release() }

        try await loadModelForLanguage(language)

        let isLongMeeting = durationSeconds >= TranscriptChunkScheduler.longMeetingThresholdSeconds
        if isLongMeeting {
            WhisperChunkLog.chunkLog.info("long-meeting path dur=\(durationSeconds, format: .fixed(precision: 1)) — overlapping windows")
            let resolved = try detectLanguageFromFilePrefix(url: url, requested: language)
            await progress(0.02)
            return try await transcribeFileChunked(
                url: url,
                durationSeconds: durationSeconds,
                language: language == .auto ? .auto : resolved,
                dictionary: dictionary,
                progress: progress,
                partialText: partialText,
                windowSeconds: TranscriptChunkScheduler.longMeetingWindowSeconds,
                overlapSeconds: TranscriptChunkScheduler.longMeetingOverlapSeconds
            )
        }

        // Decode full file once for language detect + whole-pass attempt (short/medium only).
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
                partialText: partialText,
                windowSeconds: TranscriptChunkScheduler.longMeetingWindowSeconds,
                overlapSeconds: TranscriptChunkScheduler.longMeetingOverlapSeconds
            )
        }
        guard !allSamples.isEmpty else { throw IOSWhisperError.invalidAudio }

        let resolved = try detectOrResolveLanguage(samples: allSamples, requested: language)
        await progress(0.05)

        // Whole-audio one-pass (whisper.cpp windows internally). Cap ~45 min of PCM in memory.
        let maxWholePassSamples = 16_000 * 60 * 45
        if allSamples.count <= maxWholePassSamples {
            do {
                let pass = try await transcribeSamplesWithRetries(
                    samples: allSamples,
                    durationSeconds: durationSeconds,
                    language: resolved,
                    allowEmpty: false
                )
                let droppedHindi = language == .auto
                    && WhisperLanguageSupport.likelyDroppedHindiSpans(
                        text: pass.text,
                        durationSeconds: durationSeconds,
                        resolved: pass.language
                    )
                if !WhisperLanguageSupport.needsRetry(text: pass.text, durationSeconds: durationSeconds), !droppedHindi {
                    await progress(1)
                    await partialText?(pass.text)
                    WhisperChunkLog.chunkLog.info("whole-pass ok lang=\(pass.language.rawValue, privacy: .public) chars=\(pass.text.count) dur=\(durationSeconds, format: .fixed(precision: 1))")
                    Self.clearCheckpoint(for: url)
                    return try await finalize(original: pass.text, language: pass.language, durationSeconds: durationSeconds, dictionary: dictionary)
                }
                WhisperChunkLog.chunkLog.warning("whole-pass weak/mixed (\(pass.text.count) chars / \(String(format: "%.1f", durationSeconds))s droppedHindi=\(droppedHindi)) — falling back to chunks")
            } catch {
                WhisperChunkLog.chunkLog.error("whole-pass failed: \(error.localizedDescription, privacy: .public) — chunk fallback")
            }
        }

        // Re-allow Auto per chunk so mixed Hinglish recovers Hindi+English spans.
        // Medium files use shorter windows for language agility; still overlap-stitched.
        let mediumWindow: Double = allSamples.count > 16_000 * 60 * 15 ? 180 : 30
        return try await transcribeFileChunked(
            url: url,
            durationSeconds: durationSeconds,
            language: language == .auto ? .auto : resolved,
            dictionary: dictionary,
            progress: progress,
            partialText: partialText,
            windowSeconds: mediumWindow,
            overlapSeconds: mediumWindow >= 60 ? 15 : 2
        )
    }

    /// Language detect from the first ~30s without loading the entire file into RAM.
    private func detectLanguageFromFilePrefix(url: URL, requested: SupportedLanguage) throws -> SupportedLanguage {
        guard requested == .auto else { return requested }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let probeSeconds: Double = 30
        let probeFrames = min(file.length, AVAudioFramePosition(format.sampleRate * probeSeconds))
        guard probeFrames > AVAudioFramePosition(format.sampleRate) else { return .hindi }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(probeFrames)) else {
            return .hindi
        }
        file.framePosition = 0
        try file.read(into: buffer, frameCount: AVAudioFrameCount(probeFrames))
        let samples = try Self.convertTo16kMono(buffer: buffer, format: format)
        return try detectOrResolveLanguage(samples: samples, requested: .auto)
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
        let primaryScore = WhisperLanguageSupport.scoreTranscript(primary.text, averageLogProb: primary.averageLogProb)
        let secondaryScore = WhisperLanguageSupport.scoreTranscript(secondary.text, averageLogProb: secondary.averageLogProb)
        if secondaryScore > primaryScore
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
                    return try vadPath.withCString { vadPtr in
                        params.vad = true
                        params.vad_model_path = vadPtr
                        return try self.executeWhisper(context: context, params: &params, samples: samples)
                    }
                } else {
                    params.vad = false
                    params.vad_model_path = nil
                    return try self.executeWhisper(context: context, params: &params, samples: samples)
                }
            }
        }

        if pair.0.isEmpty && !allowEmpty {
            throw IOSWhisperError.transcriptionFailed
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
        progress: @MainActor @escaping (Double) -> Void,
        partialText: (@MainActor (String) -> Void)?,
        windowSeconds: Double = TranscriptChunkScheduler.longMeetingWindowSeconds,
        overlapSeconds: Double = TranscriptChunkScheduler.longMeetingOverlapSeconds
    ) async throws -> TranscriptionResult {
        let resolvedLang: SupportedLanguage = language == .auto ? .hindi : language
        let langCode = language == .auto ? "auto" : language.rawValue

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

        let ranges = TranscriptChunkScheduler.overlappingFrameRanges(
            totalFrames: totalFrames,
            sampleRate: format.sampleRate,
            windowSeconds: windowSeconds,
            overlapSeconds: overlapSeconds
        )
        WhisperChunkLog.chunkLog.info(
            "chunked windows=\(ranges.count) window=\(windowSeconds, format: .fixed(precision: 0))s overlap=\(overlapSeconds, format: .fixed(precision: 0))s dur=\(durationSeconds, format: .fixed(precision: 1))"
        )

        var parts: [String] = []
        var chunkIndex = 0
        var lastChunkError: Error?
        var resumeFrom = 0

        if let cp = Self.loadCheckpoint(for: url), cp.chunkIndex > 0, cp.chunkIndex < ranges.count {
            parts = cp.parts
            chunkIndex = cp.chunkIndex
            resumeFrom = cp.chunkIndex
            let joined = TranscriptChunkScheduler.stitchChunkTexts(parts)
            if !joined.isEmpty {
                await partialText?(joined)
            }
            await progress(min(0.99, Double(chunkIndex) / Double(max(1, ranges.count))))
        }

        for (idx, range) in ranges.enumerated() {
            if idx < resumeFrom {
                continue
            }
            let readCount = AVAudioFrameCount(range.count)
            guard let inBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readCount) else {
                throw IOSWhisperError.invalidAudio
            }
            file.framePosition = range.start
            do {
                try file.read(into: inBuffer, frameCount: readCount)
            } catch {
                lastChunkError = error
                break
            }
            guard inBuffer.frameLength > 0 else { continue }

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
                chunkIndex = idx + 1
                continue
            }
            guard let ch = outBuffer.floatChannelData?[0], outBuffer.frameLength > 0 else {
                chunkIndex = idx + 1
                continue
            }
            let samples = Array(UnsafeBufferPointer(start: ch, count: Int(outBuffer.frameLength)))

            // Per-window language: Auto stays Auto so Hinglish can flip inside the window.
            let passLanguage: SupportedLanguage = language == .auto ? .auto : resolvedLang
            var chunkText = ""
            var chunkFailed = false
            for attempt in 1...maxChunkRetries {
                do {
                    let passLang = passLanguage == .auto ? resolvedLang : passLanguage
                    let pass = try await runWhisperPass(samples: samples, language: passLang, allowEmpty: true)
                    chunkText = pass.text
                    if language == .auto, WhisperLanguageSupport.isMostlyPlaceholders(chunkText) {
                        let alt = WhisperLanguageSupport.otherAutoLanguage(than: passLang)
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
                // Keep going — later windows may still succeed; partial text is checkpointed.
            }
            WhisperChunkLog.chunkLog.debug(
                "window=\(idx + 1)/\(ranges.count) start=\(range.start) frames=\(range.count) samples=\(samples.count) chars=\(chunkText.count) failed=\(chunkFailed) lang=\(langCode, privacy: .public)"
            )

            chunkIndex = idx + 1
            Self.saveCheckpoint(
                TranscribeCheckpoint(
                    chunkIndex: chunkIndex,
                    parts: parts,
                    framesRead: range.start + range.count
                ),
                for: url
            )
            let joined = TranscriptChunkScheduler.stitchChunkTexts(parts)
            if !joined.isEmpty {
                await partialText?(joined)
            }
            await progress(min(0.99, Double(chunkIndex) / Double(max(1, ranges.count))))
        }

        await progress(1)
        let original = WhisperLanguageSupport.filterHallucinations(
            TranscriptChunkScheduler.stitchChunkTexts(parts)
        )
        WhisperChunkLog.chunkLog.info(
            "transcribeFile chunked done windows=\(chunkIndex) dur=\(durationSeconds, format: .fixed(precision: 1)) chars=\(original.count) file=\(url.lastPathComponent, privacy: .public)"
        )

        if original.isEmpty {
            if let lastChunkError { throw lastChunkError }
            throw IOSWhisperError.transcriptionFailed
        }

        Self.clearCheckpoint(for: url)
        let finalLang: SupportedLanguage = language == .auto
            ? (WhisperLanguageSupport.containsDevanagari(original) ? .hindi : resolvedLang)
            : resolvedLang
        return try await finalize(original: original, language: finalLang, durationSeconds: durationSeconds, dictionary: dictionary)
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
