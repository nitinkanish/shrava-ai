import Foundation

public struct TranscriptionResult: Sendable {
    public let originalText: String
    public let cleanedText: String
    public let language: SupportedLanguage
    public let durationSeconds: Double
    /// Last-path-component under Recordings/, when the audio was persisted.
    public let audioFileName: String?

    public init(
        originalText: String,
        cleanedText: String,
        language: SupportedLanguage,
        durationSeconds: Double,
        audioFileName: String? = nil
    ) {
        self.originalText = originalText
        self.cleanedText = cleanedText
        self.language = language
        self.durationSeconds = durationSeconds
        self.audioFileName = audioFileName
    }
}
