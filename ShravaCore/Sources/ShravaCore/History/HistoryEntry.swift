import Foundation

public enum TranscriptionState: String, Codable, Sendable, Hashable {
    case complete
    case pending
    /// Some chunks produced text but the run did not finish cleanly — tap Retry to continue.
    case partial
    case failed
}

public struct HistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var originalText: String
    public var cleanedText: String
    public let language: String
    public let timestamp: Date
    public let durationSeconds: Double
    public let appBundleIdentifier: String?
    /// pending / failed / complete — older entries decode as complete.
    public var transcriptionState: TranscriptionState
    /// File name under Documents/Recordings (or absolute lastPathComponent).
    public var audioFileName: String?
    /// 0...1 while pending.
    public var transcriptionProgress: Double

    public init(
        id: UUID = UUID(),
        originalText: String,
        cleanedText: String,
        language: String,
        timestamp: Date = Date(),
        durationSeconds: Double,
        appBundleIdentifier: String? = nil,
        transcriptionState: TranscriptionState = .complete,
        audioFileName: String? = nil,
        transcriptionProgress: Double = 1
    ) {
        self.id = id
        self.originalText = originalText
        self.cleanedText = cleanedText
        self.language = language
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.appBundleIdentifier = appBundleIdentifier
        self.transcriptionState = transcriptionState
        self.audioFileName = audioFileName
        self.transcriptionProgress = transcriptionProgress
    }

    enum CodingKeys: String, CodingKey {
        case id, originalText, cleanedText, language, timestamp, durationSeconds
        case appBundleIdentifier, transcriptionState, audioFileName, transcriptionProgress
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        originalText = try c.decode(String.self, forKey: .originalText)
        cleanedText = try c.decode(String.self, forKey: .cleanedText)
        language = try c.decode(String.self, forKey: .language)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        durationSeconds = try c.decode(Double.self, forKey: .durationSeconds)
        appBundleIdentifier = try c.decodeIfPresent(String.self, forKey: .appBundleIdentifier)
        transcriptionState = try c.decodeIfPresent(TranscriptionState.self, forKey: .transcriptionState) ?? .complete
        audioFileName = try c.decodeIfPresent(String.self, forKey: .audioFileName)
        transcriptionProgress = try c.decodeIfPresent(Double.self, forKey: .transcriptionProgress)
            ?? (transcriptionState == .complete ? 1 : 0)
    }

    public var isPendingOrFailed: Bool {
        transcriptionState == .pending || transcriptionState == .partial || transcriptionState == .failed
    }

    /// True when History should surface a clear Regenerate / Retry CTA.
    public var needsTranscriptRegenerateCTA: Bool {
        guard audioFileName != nil else { return false }
        if isPendingOrFailed { return true }
        let body = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return true }
        if body.hasPrefix("Transcribing") || body.hasPrefix("Recovered") || body.hasPrefix("Transcription failed") {
            return true
        }
        // Suspiciously short for a long capture (stuck / truncated "complete").
        if durationSeconds >= 20 * 60 {
            let words = body.split { $0.isWhitespace || $0.isNewline }.count
            let minExpected = max(80, Int(durationSeconds / 12)) // ~5 wpm floor
            if words < minExpected { return true }
        }
        return false
    }

    /// Placeholder / progress copy that should not be kept as the prior transcript.
    public var isPlaceholderTranscript: Bool {
        let body = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return true }
        return body.hasPrefix("Transcribing")
            || body.hasPrefix("Recovered")
            || body.hasPrefix("Transcription failed")
            || body.hasPrefix("Regenerating")
    }

    public var displayTitle: String {
        switch transcriptionState {
        case .pending:
            let pct = Int((transcriptionProgress * 100).rounded())
            if cleanedText.hasPrefix("Recovered") || cleanedText.hasPrefix("Transcribing") {
                return cleanedText.contains("%") ? cleanedText : "Transcribing… \(pct)%"
            }
            return "Transcribing… \(pct)%"
        case .partial:
            let body = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty || body.hasPrefix("Recovered") || body.hasPrefix("Transcribing") {
                return "Partial transcript — tap to retry"
            }
            return body
        case .failed:
            let body = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
            // Don't scream "failed" for unrecovered orphans waiting on first attempt.
            if body.hasPrefix("Recovered") {
                return body
            }
            return body.isEmpty ? "Transcription failed — tap to retry" : body
        case .complete:
            return cleanedText
        }
    }
}

public actor HistoryManager {
    private var entries: [HistoryEntry] = []
    private let maxEntries: Int
    private let storageURL: URL?

    public init(maxEntries: Int = 1000, storageURL: URL? = nil) {
        self.maxEntries = maxEntries
        self.storageURL = storageURL
        Task { await loadFromDisk() }
    }

    public func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast()
        }
        Task { await saveToDisk() }
    }

    public func update(_ entry: HistoryEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else {
            add(entry)
            return
        }
        entries[idx] = entry
        Task { await saveToDisk() }
    }

    public func getAll() -> [HistoryEntry] {
        return entries
    }

    public func get(id: UUID) -> HistoryEntry? {
        entries.first { $0.id == id }
    }

    public func getRecent(limit: Int = 50) -> [HistoryEntry] {
        return Array(entries.prefix(limit))
    }

    public func search(query: String) -> [HistoryEntry] {
        let lowercasedQuery = query.lowercased()
        return entries.filter { entry in
            entry.cleanedText.lowercased().contains(lowercasedQuery) ||
            entry.originalText.lowercased().contains(lowercasedQuery)
        }
    }

    public func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        Task { await saveToDisk() }
    }

    public func clear() {
        entries.removeAll()
        Task { await saveToDisk() }
    }

    public func replaceAll(_ newEntries: [HistoryEntry]) {
        entries = Array(newEntries.prefix(maxEntries))
        Task { await saveToDisk() }
    }

    private func loadFromDisk() {
        guard let url = storageURL else { return }
        do {
            let data = try Data(contentsOf: url)
            entries = try JSONDecoder().decode([HistoryEntry].self, from: data)
        } catch {
            entries = []
        }
    }

    private func saveToDisk() {
        guard let url = storageURL else { return }
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to save history: \(error)")
        }
    }
}
