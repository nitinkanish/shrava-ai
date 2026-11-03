import Foundation

public struct HistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let originalText: String
    public let cleanedText: String
    public let language: String
    public let timestamp: Date
    public let durationSeconds: Double
    public let appBundleIdentifier: String?
    
    public init(
        id: UUID = UUID(),
        originalText: String,
        cleanedText: String,
        language: String,
        timestamp: Date = Date(),
        durationSeconds: Double,
        appBundleIdentifier: String? = nil
    ) {
        self.id = id
        self.originalText = originalText
        self.cleanedText = cleanedText
        self.language = language
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.appBundleIdentifier = appBundleIdentifier
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
    
    public func getAll() -> [HistoryEntry] {
        return entries
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
