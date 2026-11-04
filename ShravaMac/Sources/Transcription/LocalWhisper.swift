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

final class LocalWhisper: @unchecked Sendable {
    static let shared = LocalWhisper()

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


    /// Split long/mixed audio into ~12s windows and decode each with auto language (recovers Hinglish).
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
        return parts.joined(separator: " ")
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
