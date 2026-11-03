import Foundation

public struct Snippet: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let trigger: String
    public let content: String
    public let isEnabled: Bool
    public let createdAt: Date
    
    public init(
        id: UUID = UUID(),
        trigger: String,
        content: String,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.trigger = trigger
        self.content = content
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
    
    public func toggled() -> Snippet {
        Snippet(
            id: id,
            trigger: trigger,
            content: content,
            isEnabled: !isEnabled,
            createdAt: createdAt
        )
    }
}

public actor SnippetManager {
    private var snippets: [Snippet] = []
    private let storageURL: URL?
    
    public init(storageURL: URL? = nil) {
        self.storageURL = storageURL
        Task { await loadFromDisk() }
    }
    
    public func add(_ snippet: Snippet) {
        if !snippets.contains(where: { $0.trigger.lowercased() == snippet.trigger.lowercased() }) {
            snippets.append(snippet)
            Task { await saveToDisk() }
        }
    }
    
    public func update(_ snippet: Snippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
            Task { await saveToDisk() }
        }
    }
    
    public func delete(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        Task { await saveToDisk() }
    }
    
    public func getAll() -> [Snippet] {
        return snippets
    }
    
    public func find(byTrigger trigger: String) -> Snippet? {
        return snippets.first { $0.trigger.lowercased() == trigger.lowercased() && $0.isEnabled }
    }
    
    public func replaceAll(_ newSnippets: [Snippet]) {
        snippets = newSnippets
        Task { await saveToDisk() }
    }
    
    private func loadFromDisk() {
        guard let url = storageURL else { return }
        do {
            let data = try Data(contentsOf: url)
            snippets = try JSONDecoder().decode([Snippet].self, from: data)
        } catch {
            snippets = []
        }
    }
    
    private func saveToDisk() {
        guard let url = storageURL else { return }
        do {
            let data = try JSONEncoder().encode(snippets)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to save snippets: \(error)")
        }
    }
}
