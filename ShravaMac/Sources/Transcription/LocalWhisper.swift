import Foundation
import ShravaCore

/// Runs the open-source Whisper model locally through whisper.cpp (Metal-accelerated). No network, no API key.
enum LocalWhisperError: LocalizedError {
    case binaryMissing, modelMissing(String), failed(String)
    var errorDescription: String? {
        switch self {
        case .binaryMissing: return "whisper.cpp is not installed. Run: brew install whisper-cpp"
        case .modelMissing(let p): return "Whisper model not found at \(p)"
        case .failed(let m): return "Local Whisper failed: \(m)"
        }
    }
}

private final class LocalWhisperRunGate: @unchecked Sendable {
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

final class LocalWhisper: @unchecked Sendable {
    static let shared = LocalWhisper()
    /// Cap concurrent whisper-cli invocations (regenerate must not stack).
    private let runGate = LocalWhisperRunGate()

    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shrava/models", isDirectory: true)
    }

    static var recordingsDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shrava/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Preferred models largest → smallest. Retry may step down the list toward a larger available file.
    private static let preferredModels = [
        "ggml-large-v3-turbo-q5_0.bin",
        "ggml-large-v3-turbo.bin",
        "ggml-medium.bin",
        "ggml-small.bin",
        "ggml-base.bin"
    ]

    var modelURL: URL? { Self.availableModels().first }

    /// All installed models ordered preferred-first.
    static func availableModels() -> [URL] {
        preferredModels.compactMap { name in
            let url = modelsDirectory.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    var binaryPath: String? {
        ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli", "/opt/homebrew/bin/whisper-cpp"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func transcribe(audioData: Data, durationSeconds: Double, language: SupportedLanguage, dictionary: PersonalDictionary, existingURL: URL? = nil) async throws -> TranscriptionResult {
        await runGate.acquire()
        defer { runGate.release() }

        guard let bin = binaryPath else { throw LocalWhisperError.binaryMissing }
        let models = Self.availableModels()
        guard let primaryModel = models.first else {
            throw LocalWhisperError.modelMissing(Self.modelsDirectory.path)
        }

        // Prefer the recorder's on-disk WAV so History can play the same file.
        let wav: URL
        if let existingURL, FileManager.default.fileExists(atPath: existingURL.path) {
            wav = existingURL
        } else {
            wav = Self.recordingsDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            try audioData.write(to: wav)
        }

        if durationSeconds >= TranscriptChunkScheduler.longMeetingThresholdSeconds {
            NSLog("Shrava: long-meeting Mac path dur=%.1fs — overlapping windows", durationSeconds)
            return try await transcribeLongFile(
                bin: bin,
                model: models.first!,
                wav: wav,
                durationSeconds: durationSeconds,
                language: language,
                dictionary: dictionary,
                progress: nil,
                partialText: nil
            )
        }

        let resolved = try await resolveLanguage(
            bin: bin,
            model: primaryModel,
            wav: wav,
            requested: language,
            durationSeconds: durationSeconds
        )

        var usedLanguage = resolved
        var usedModel = primaryModel
        var raw = try await runWhisper(bin: bin, model: usedModel, wav: wav, languageCode: usedLanguage.rawValue)
        var original = Self.cleanRawOutput(raw)

        if WhisperLanguageSupport.needsRetry(text: original, durationSeconds: durationSeconds) {
            let alternate = WhisperLanguageSupport.otherAutoLanguage(than: usedLanguage)
            NSLog("Shrava: Whisper retry with language=\(alternate.rawValue) after weak transcript (\(original.count) chars / \(String(format: "%.1f", durationSeconds))s)")
            let altRaw = try await runWhisper(bin: bin, model: usedModel, wav: wav, languageCode: alternate.rawValue)
            let altText = Self.cleanRawOutput(altRaw)
            if !WhisperLanguageSupport.needsRetry(text: altText, durationSeconds: durationSeconds)
                || altText.count > original.count {
                original = altText
                usedLanguage = alternate
                raw = altRaw
            }
        }

        // Optional larger-model retry when still weak and another model is available.
        if WhisperLanguageSupport.needsRetry(text: original, durationSeconds: durationSeconds), models.count > 1 {
            // preferredModels is large→small; "larger" for quality means earlier in the list.
            // If primary is already the largest installed, try the next different one anyway
            // (e.g. base failed → try small if somehow ordered differently). Prefer first unused.
            for candidate in models where candidate != usedModel {
                NSLog("Shrava: Whisper retry with model=\(candidate.lastPathComponent)")
                let retryRaw = try await runWhisper(bin: bin, model: candidate, wav: wav, languageCode: usedLanguage.rawValue)
                let retryText = Self.cleanRawOutput(retryRaw)
                if !WhisperLanguageSupport.needsRetry(text: retryText, durationSeconds: durationSeconds)
                    || retryText.count > original.count {
                    original = retryText
                    usedModel = candidate
                    raw = retryRaw
                    break
                }
            }
        }

        let droppedHindi = language == .auto
            && WhisperLanguageSupport.likelyDroppedHindiSpans(
                text: original,
                durationSeconds: durationSeconds,
                resolved: usedLanguage
            )
        if WhisperLanguageSupport.needsRetry(text: original, durationSeconds: durationSeconds) || droppedHindi {
            NSLog("Shrava: Whisper chunked retry (droppedHindi=\(droppedHindi))")
            let chunkRaw = try await transcribeChunked(bin: bin, model: usedModel, wav: wav, languageCode: "auto")
            let chunkText = Self.cleanRawOutput(chunkRaw)
            if chunkText.count > original.count
                || WhisperLanguageSupport.containsDevanagari(chunkText)
                || !WhisperLanguageSupport.needsRetry(text: chunkText, durationSeconds: durationSeconds) {
                original = chunkText
                raw = chunkRaw
            }
        }

        var cleaned = original
        if SettingsManager.shared.settings.autoCleanup { cleaned = TranscriptionCleanup.localCleanup(cleaned) }
        cleaned = await dictionary.applyCorrections(to: cleaned)

        let settings = SettingsManager.shared.settings
        if settings.enhanceTranscript, OllamaSecrets.hasAPIKey() {
            do {
                let hint = usedLanguage == .hindi || usedLanguage == .auto ? "Hindi and English" : usedLanguage.displayName
                let enhanced = try await OllamaClient.shared.enhanceTranscript(cleaned, languageHint: hint)
                if !enhanced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cleaned = enhanced
                }
            } catch {
                NSLog("Shrava: enhance transcript skipped: \(error.localizedDescription)")
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
                NSLog("Shrava: roman Hinglish skipped: \(error.localizedDescription)")
            }
        }

        return TranscriptionResult(
            originalText: original,
            cleanedText: cleaned,
            language: usedLanguage == .auto ? resolved : usedLanguage,
            durationSeconds: durationSeconds,
            audioFileName: wav.lastPathComponent
        )
    }

    /// Detect en/hi on the first ~30s when picker is Auto; otherwise use the fixed language.
    private func resolveLanguage(
        bin: String,
        model: URL,
        wav: URL,
        requested: SupportedLanguage,
        durationSeconds: Double
    ) async throws -> SupportedLanguage {
        guard requested == .auto else { return requested }

        let probe = try Self.writePrefixWAV(from: wav, maxSeconds: 30)
        defer { try? FileManager.default.removeItem(at: probe) }

        let combined = try await runProcess(
            bin: bin,
            args: ["-m", model.path, "-f", probe.path, "-l", "auto", "-dl", "-t", "\(Self.threadCount)", "-np"]
        )
        if let parsed = WhisperLanguageSupport.parseDetectedLanguage(from: combined) {
            // When only one code is returned, also probe the other for mixed speech if probs are mid-range.
            let code = parsed.code
            if code == "en" || code == "hi" {
                if parsed.probability > 0 && parsed.probability < 0.55 {
                    // Ambiguous — prefer Hindi for Hinglish meetings.
                    return WhisperLanguageSupport.resolveAuto(
                        detectedCode: code,
                        enProbability: code == "en" ? parsed.probability : 1.0 - parsed.probability,
                        hiProbability: code == "hi" ? parsed.probability : 1.0 - parsed.probability
                    )
                }
                return WhisperLanguageSupport.resolveAuto(detectedCode: code, enProbability: code == "en" ? parsed.probability : nil, hiProbability: code == "hi" ? parsed.probability : nil)
            }
            return WhisperLanguageSupport.resolveAuto(detectedCode: code)
        }
        // Detection failed — prefer Hindi for mixed meetings.
        return .hindi
    }


    /// Re-run Whisper on an existing recording (History regenerate). Keeps the WAV/m4a on disk.
    func transcribeExistingFile(
        url: URL,
        durationSeconds: Double,
        language: SupportedLanguage,
        dictionary: PersonalDictionary,
        progress: (@MainActor (Double) -> Void)? = nil,
        partialText: (@MainActor (String) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        guard let bin = binaryPath else { throw LocalWhisperError.binaryMissing }
        let models = Self.availableModels()
        guard let primaryModel = models.first else {
            throw LocalWhisperError.modelMissing(Self.modelsDirectory.path)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LocalWhisperError.failed("Audio file missing")
        }
        if durationSeconds >= TranscriptChunkScheduler.longMeetingThresholdSeconds
            || url.pathExtension.lowercased() != "wav" {
            await runGate.acquire()
            defer { runGate.release() }
            return try await transcribeLongFile(
                bin: bin,
                model: primaryModel,
                wav: url,
                durationSeconds: durationSeconds,
                language: language,
                dictionary: dictionary,
                progress: progress,
                partialText: partialText
            )
        }
        // Short WAV: standard pipeline (owns the gate).
        return try await transcribe(
            audioData: Data(),
            durationSeconds: durationSeconds,
            language: language,
            dictionary: dictionary,
            existingURL: url
        )
    }

    /// Stream overlapping 5–10 min windows for multi-hour meetings (full file kept on disk).
    private func transcribeLongFile(
        bin: String,
        model: URL,
        wav: URL,
        durationSeconds: Double,
        language: SupportedLanguage,
        dictionary: PersonalDictionary,
        progress: (@MainActor (Double) -> Void)?,
        partialText: (@MainActor (String) -> Void)?
    ) async throws -> TranscriptionResult {
        let resolved = try await resolveLanguage(
            bin: bin,
            model: model,
            wav: wav,
            requested: language,
            durationSeconds: min(durationSeconds, 30)
        )
        await progress?(0.02)

        let workURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-long-canonical.wav")
        defer { try? FileManager.default.removeItem(at: workURL) }
        if wav.pathExtension.lowercased() == "wav" {
            try Self.canonicalizePCM16MonoWAV(from: wav, to: workURL)
        } else {
            try await Self.convertToWAV16kMono(from: wav, to: workURL)
        }

        let data = try Data(contentsOf: workURL)
        let header = 44
        let bytesPerSecond = 32_000
        let totalPCM = max(0, data.count - header)
        let totalFrames = Int64(totalPCM / 2) // 16-bit mono
        let ranges = TranscriptChunkScheduler.overlappingFrameRanges(
            totalFrames: totalFrames,
            sampleRate: 16_000,
            windowSeconds: TranscriptChunkScheduler.longMeetingWindowSeconds,
            overlapSeconds: TranscriptChunkScheduler.longMeetingOverlapSeconds
        )
        NSLog("Shrava: long-meeting windows=%d window=%.0fs", ranges.count, TranscriptChunkScheduler.longMeetingWindowSeconds)

        var parts: [String] = []
        for (idx, range) in ranges.enumerated() {
            let byteStart = header + Int(range.start) * 2
            let byteCount = Int(range.count) * 2
            let end = min(data.count, byteStart + byteCount)
            guard byteStart < data.count else { continue }
            let pcm = data[byteStart..<end]
            var chunk = Data()
            chunk.append(contentsOf: data.prefix(header))
            chunk.append(pcm)
            let dataSize = UInt32(chunk.count - header).littleEndian
            let fileSize = UInt32(chunk.count - 8).littleEndian
            withUnsafeBytes(of: fileSize) { chunk.replaceSubrange(4..<8, with: $0) }
            withUnsafeBytes(of: dataSize) { chunk.replaceSubrange(40..<44, with: $0) }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("shrava-long-\(idx).wav")
            try chunk.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let code = language == .auto ? "auto" : resolved.rawValue
            let raw = try await runWhisper(bin: bin, model: model, wav: tmp, languageCode: code)
            let text = Self.cleanRawOutput(raw)
            if !text.isEmpty { parts.append(text) }
            let joined = TranscriptChunkScheduler.stitchChunkTexts(parts)
            await partialText?(joined)
            await progress?(min(0.99, Double(idx + 1) / Double(max(1, ranges.count))))
        }

        var original = TranscriptChunkScheduler.stitchChunkTexts(parts)
        if original.isEmpty {
            throw LocalWhisperError.failed("Empty transcript from long-meeting windows")
        }

        var cleaned = original
        if SettingsManager.shared.settings.autoCleanup { cleaned = TranscriptionCleanup.localCleanup(cleaned) }
        cleaned = await dictionary.applyCorrections(to: cleaned)

        let settings = SettingsManager.shared.settings
        if settings.enhanceTranscript, OllamaSecrets.hasAPIKey() {
            do {
                let hint = resolved == .hindi || language == .auto ? "Hindi and English" : resolved.displayName
                let enhanced = try await OllamaClient.shared.enhanceTranscript(cleaned, languageHint: hint)
                if !enhanced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cleaned = enhanced
                }
            } catch {
                NSLog("Shrava: enhance transcript skipped: \(error.localizedDescription)")
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
                NSLog("Shrava: roman Hinglish skipped: \(error.localizedDescription)")
            }
        }

        await progress?(1)
        return TranscriptionResult(
            originalText: original,
            cleanedText: cleaned,
            language: language == .auto
                ? (WhisperLanguageSupport.containsDevanagari(original) ? .hindi : resolved)
                : resolved,
            durationSeconds: durationSeconds,
            audioFileName: wav.lastPathComponent
        )
    }

    /// Split mixed audio into short windows (Hinglish recovery for medium clips).
    private func transcribeChunked(bin: String, model: URL, wav: URL, languageCode: String) async throws -> String {
        let data = try Data(contentsOf: wav)
        let header = 44
        let bytesPerSecond = 32_000
        let chunkSeconds = 12.0
        let chunkBytes = Int(chunkSeconds * Double(bytesPerSecond))
        guard data.count > header + chunkBytes else {
            return try await runWhisper(bin: bin, model: model, wav: wav, languageCode: languageCode)
        }
        var parts: [String] = []
        var offset = header
        var index = 0
        while offset < data.count {
            let end = min(data.count, offset + chunkBytes)
            let pcm = data[offset..<end]
            var chunk = Data()
            chunk.append(contentsOf: data.prefix(header))
            chunk.append(pcm)
            let dataSize = UInt32(chunk.count - header).littleEndian
            let fileSize = UInt32(chunk.count - 8).littleEndian
            withUnsafeBytes(of: fileSize) { chunk.replaceSubrange(4..<8, with: $0) }
            withUnsafeBytes(of: dataSize) { chunk.replaceSubrange(40..<44, with: $0) }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("shrava-chunk-\(index).wav")
            try chunk.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let code = languageCode == "auto" || languageCode == "hi" || languageCode == "en" ? "auto" : languageCode
            let raw = try await runWhisper(bin: bin, model: model, wav: tmp, languageCode: code)
            let text = Self.cleanRawOutput(raw)
            if !text.isEmpty { parts.append(text) }
            offset = end
            index += 1
        }
        return TranscriptChunkScheduler.stitchChunkTexts(parts)
    }

    private static func convertToWAV16kMono(from source: URL, to dest: URL) async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-afc.wav")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            p.arguments = [
                source.path,
                tmp.path,
                "-f", "WAVE",
                "-d", "LEI16@16000",
                "-c", "1"
            ]
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: LocalWhisperError.failed("afconvert failed (\(proc.terminationStatus))"))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        // afconvert emits extensible fmt + padding chunks — rewrite a clean 44-byte PCM WAV
        // so byte-window slicing in transcribeLongFile stays aligned.
        try canonicalizePCM16MonoWAV(from: tmp, to: dest)
    }

    /// Locate the `data` chunk and rewrite as classic PCM16 mono WAV (44-byte header).
    private static func canonicalizePCM16MonoWAV(from source: URL, to dest: URL) throws {
        let data = try Data(contentsOf: source)
        guard data.count > 44, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else {
            throw LocalWhisperError.failed("Invalid WAV from afconvert")
        }
        var pos = 12
        var pcm: Data?
        var sampleRate: UInt32 = 16_000
        var channels: UInt16 = 1
        var bits: UInt16 = 16
        while pos + 8 <= data.count {
            let id = String(data: data[pos..<pos+4], encoding: .ascii) ?? ""
            let size = Int(data.subdata(in: (pos+4)..<(pos+8)).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
            let payloadStart = pos + 8
            let payloadEnd = min(data.count, payloadStart + size)
            if id == "fmt ", size >= 16 {
                channels = data.subdata(in: (payloadStart+2)..<(payloadStart+4)).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
                sampleRate = data.subdata(in: (payloadStart+4)..<(payloadStart+8)).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
                bits = data.subdata(in: (payloadStart+14)..<(payloadStart+16)).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
            } else if id == "data" {
                pcm = data.subdata(in: payloadStart..<payloadEnd)
                break
            }
            pos = payloadStart + size + (size % 2)
        }
        guard let pcm, !pcm.isEmpty else {
            throw LocalWhisperError.failed("WAV missing data chunk")
        }
        var out = Data()
        out.append(contentsOf: "RIFF".utf8)
        var fileSize = UInt32(36 + pcm.count).littleEndian
        withUnsafeBytes(of: &fileSize) { out.append(contentsOf: $0) }
        out.append(contentsOf: "WAVEfmt ".utf8)
        var fmtSize: UInt32 = 16
        var audioFormat: UInt16 = 1
        var blockAlign = UInt16(channels * bits / 8)
        var byteRate = UInt32(sampleRate) * UInt32(blockAlign)
        var ch = channels.littleEndian
        var sr = sampleRate.littleEndian
        var br = byteRate.littleEndian
        var ba = blockAlign.littleEndian
        var bps = bits.littleEndian
        withUnsafeBytes(of: &fmtSize) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &audioFormat) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &ch) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &sr) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &br) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &ba) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &bps) { out.append(contentsOf: $0) }
        out.append(contentsOf: "data".utf8)
        var dataSize = UInt32(pcm.count).littleEndian
        withUnsafeBytes(of: &dataSize) { out.append(contentsOf: $0) }
        out.append(pcm)
        try out.write(to: dest, options: .atomic)
    }

    private func runWhisper(bin: String, model: URL, wav: URL, languageCode: String) async throws -> String {
        var args = [
            "-m", model.path,
            "-f", wav.path,
            "-l", languageCode,
            "-t", "\(Self.threadCount)",
            "-nt",
            "-np",
            "-bs", "5",
            "-mc", "0",
            "-tp", "0",
            "-tpi", "0.2",
            "--suppress-nst",
            "--prompt", WhisperLanguageSupport.hinglishInitialPrompt
        ]
        let vad = Self.modelsDirectory.appendingPathComponent("ggml-silero-v5.1.2.bin")
        if FileManager.default.fileExists(atPath: vad.path) {
            args += ["--vad", "-vm", vad.path]
        }
        return try await runProcess(bin: bin, args: args)
    }

    private func runProcess(bin: String, args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.terminationHandler = { proc in
                let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                // detect-language writes to stderr; transcription text is on stdout.
                if proc.terminationStatus == 0 {
                    cont.resume(returning: o + "\n" + e)
                } else {
                    cont.resume(throwing: LocalWhisperError.failed(String(e.suffix(300))))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: LocalWhisperError.failed(error.localizedDescription)) }
        }
    }

    private static var threadCount: Int {
        let saved = UserDefaults.standard.integer(forKey: "whisperThreads")
        return saved > 0 ? saved : max(4, ProcessInfo.processInfo.activeProcessorCount - 2)
    }

    private static func cleanRawOutput(_ raw: String) -> String {
        let lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                // Drop whisper-cli log noise that can leak into stdout when -np is incomplete.
                if line.hasPrefix("whisper_") { return false }
                if line.hasPrefix("ggml_") { return false }
                if line.hasPrefix("system_info") { return false }
                if line.hasPrefix("main:") { return false }
                if line.hasPrefix("read_audio") { return false }
                if WhisperLanguageSupport.isPlaceholderLine(line) { return false }
                if line.hasPrefix("[") && line.contains("-->") { return false } // timestamps
                return true
            }
        let joined = lines.joined(separator: " ")
        return WhisperLanguageSupport.filterHallucinations(joined)
    }

    /// Copy the first `maxSeconds` of a WAV into a new temp file for language detection.
    private static func writePrefixWAV(from source: URL, maxSeconds: Double) throws -> URL {
        let data = try Data(contentsOf: source)
        // PCM WAV: 44-byte header + 16-bit mono @ 16 kHz → 32000 bytes/sec.
        let header = 44
        let bytesPerSecond = 32_000
        let keep = header + Int(maxSeconds * Double(bytesPerSecond))
        let prefix = data.prefix(min(data.count, keep))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-probe.wav")
        try Data(prefix).write(to: out)
        // Patch data-size / file-size in header when truncated.
        if prefix.count > header, prefix.count < data.count {
            var mutable = Data(prefix)
            let dataSize = UInt32(mutable.count - header).littleEndian
            let fileSize = UInt32(mutable.count - 8).littleEndian
            withUnsafeBytes(of: fileSize) { mutable.replaceSubrange(4..<8, with: $0) }
            withUnsafeBytes(of: dataSize) { mutable.replaceSubrange(40..<44, with: $0) }
            try mutable.write(to: out)
        }
        return out
    }
}
