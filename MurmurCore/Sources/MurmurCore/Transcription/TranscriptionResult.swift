import Foundation

public struct TranscriptionResult: Sendable {
    public let originalText: String
    public let cleanedText: String
    public let language: SupportedLanguage
    public let durationSeconds: Double
    
    public init(originalText: String, cleanedText: String, language: SupportedLanguage, durationSeconds: Double) {
        self.originalText = originalText
        self.cleanedText = cleanedText
        self.language = language
        self.durationSeconds = durationSeconds
    }
}

