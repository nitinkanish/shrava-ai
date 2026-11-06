import Foundation

/// Shared, testable guardrails; iPhone windows are intentionally much smaller than Mac.
public enum TranscriptionRecoveryPolicy {
    public static let iosWindowSeconds: Double = 60
    public static let iosOverlapSeconds: Double = 5

    public static func languageForWindow(requested: SupportedLanguage, detected: SupportedLanguage) -> SupportedLanguage {
        requested == .auto ? detected : requested
    }

    public static func validModelByteCount(_ bytes: Int64, expected: Int64) -> Bool {
        bytes == expected // The catalog pins concrete files, not arbitrary/partial HTTP bodies.
    }

    public static func interruptedEntry(_ entry: HistoryEntry) -> HistoryEntry {
        guard entry.transcriptionState == .pending,
              !entry.cleanedText.hasPrefix("Recovered recording — tap") else { return entry }
        var result = entry
        result.transcriptionError = "Processing was interrupted. Your audio is saved. Tap Regenerate transcript to retry."
        result.transcriptionState = entry.isPlaceholderTranscript ? .failed : .partial
        if entry.isPlaceholderTranscript { result.cleanedText = "Transcription interrupted — tap to retry" }
        return result
    }
}

/// Checkpoints advance only after a successful window (including genuine silence).
/// Fingerprints prevent a retry with different settings/window sizes skipping audio.
public struct TranscriptCheckpoint: Codable, Equatable, Sendable {
    public var fingerprint: String
    public var nextWindow: Int
    public var parts: [String]

    public init(fingerprint: String, nextWindow: Int = 0, parts: [String] = []) {
        self.fingerprint = fingerprint
        self.nextWindow = nextWindow
        self.parts = parts
    }

    public func canResume(fingerprint: String, windowCount: Int) -> Bool {
        self.fingerprint == fingerprint && nextWindow >= 0 && nextWindow <= windowCount
            && parts.count == nextWindow
    }

    public mutating func finishWindow(text: String) {
        parts.append(text)
        nextWindow += 1
    }
}
