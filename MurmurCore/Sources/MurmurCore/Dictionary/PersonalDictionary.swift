import Foundation

public struct DictionaryEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let spoken: String
    public let written: String
    public let isEnabled: Bool
    public let createdAt: Date
    
    public init(
        id: UUID = UUID(),
        spoken: String,
        written: String,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.spoken = spoken
        self.written = written
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
    
    public func toggled() -> DictionaryEntry {
        DictionaryEntry(
            id: id,
            spoken: spoken,
            written: written,
            isEnabled: !isEnabled,
            createdAt: createdAt
        )
    }
}

public actor PersonalDictionary {
    private var entries: [DictionaryEntry] = []
    private let storageURL: URL?
    
    public init(storageURL: URL? = nil) {
        self.storageURL = storageURL
        Task { await loadFromDisk() }
    }
    
    public func add(_ entry: DictionaryEntry) {
        if !entries.contains(where: { $0.spoken.lowercased() == entry.spoken.lowercased() }) {
            entries.append(entry)
            Task { await saveToDisk() }
        }
    }
    
    public func update(_ entry: DictionaryEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
            Task { await saveToDisk() }
        }
    }
    
    public func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        Task { await saveToDisk() }
    }
    
    public func getAll() -> [DictionaryEntry] {
        return entries
    }
    
    public func getEnabled() -> [DictionaryEntry] {
        return entries.filter { $0.isEnabled }
    }
    
    public func applyCorrections(to text: String) -> String {
        var result = text
        let enabledEntries = entries.filter { $0.isEnabled }
        
        for entry in enabledEntries {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: entry.spoken))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: range,
                    withTemplate: entry.written
                )
            }
        }
        
        return result
    }
    
    public func replaceAll(_ newEntries: [DictionaryEntry]) {
        entries = newEntries
        Task { await saveToDisk() }
    }
    
    private func loadFromDisk() {
        guard let url = storageURL else { return }
        do {
            let data = try Data(contentsOf: url)
            entries = try JSONDecoder().decode([DictionaryEntry].self, from: data)
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
            print("Failed to save dictionary: \(error)")
        }
    }
}
