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

    var modelURL: URL? {
        let preferred = ["ggml-large-v3-turbo-q5_0.bin", "ggml-large-v3-turbo.bin", "ggml-medium.bin", "ggml-small.bin", "ggml-base.bin"]
        for name in preferred {
            let url = Self.modelsDirectory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    var binaryPath: String? {
        ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli", "/opt/homebrew/bin/whisper-cpp"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func transcribe(audioData: Data, durationSeconds: Double, language: SupportedLanguage, dictionary: PersonalDictionary) async throws -> TranscriptionResult {
        guard let bin = binaryPath else { throw LocalWhisperError.binaryMissing }
        guard let model = modelURL else { throw LocalWhisperError.modelMissing(Self.modelsDirectory.path) }

        let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try audioData.write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        let lang = language == .auto ? "auto" : language.rawValue
        let saved = UserDefaults.standard.integer(forKey: "whisperThreads"); let threads = saved > 0 ? saved : max(4, ProcessInfo.processInfo.activeProcessorCount - 2)
        let args = ["-m", model.path, "-f", wav.path, "-l", lang, "-t", "\(threads)", "-nt", "-np"]

        let raw: String = try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            p.terminationHandler = { proc in
                let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 { cont.resume(returning: o) }
                else { cont.resume(throwing: LocalWhisperError.failed(String(e.suffix(300)))) }
            }
            do { try p.run() } catch { cont.resume(throwing: LocalWhisperError.failed(error.localizedDescription)) }
        }

        let original = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var cleaned = original
        if SettingsManager.shared.settings.autoCleanup { cleaned = TranscriptionCleanup.localCleanup(cleaned) }
        cleaned = await dictionary.applyCorrections(to: cleaned)

        return TranscriptionResult(originalText: original, cleanedText: cleaned, language: language, durationSeconds: durationSeconds)
    }

}
