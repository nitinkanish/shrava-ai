import Foundation

/// Persists MeetingBrief values keyed by HistoryEntry id under Application Support/Shrava/briefs.json
public actor BriefStore {
    public static let shared = BriefStore()

    private var cache: [UUID: MeetingBrief] = [:]
    private var loaded = false
    private let overrideURL: URL?

    private var fileURL: URL? {
        if let overrideURL { return overrideURL }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Shrava", isDirectory: true)
            .appendingPathComponent("briefs.json")
    }

    public init(storageURL: URL? = nil) {
        self.overrideURL = storageURL
    }

    public func load() async {
        guard !loaded else { return }
        loaded = true
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let map = try? dec.decode([String: MeetingBrief].self, from: data) {
            cache = Dictionary(uniqueKeysWithValues: map.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        }
    }

    public func brief(for id: UUID) async -> MeetingBrief? {
        await load()
        return cache[id]
    }

    public func save(_ brief: MeetingBrief, for id: UUID) async throws {
        await load()
        cache[id] = brief
        try persist()
    }

    public func delete(for id: UUID) async {
        await load()
        cache.removeValue(forKey: id)
        try? persist()
    }

    public func clear() async {
        cache.removeAll()
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
    }

    private func persist() throws {
        guard let url = fileURL else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let map = Dictionary(uniqueKeysWithValues: cache.map { ($0.key.uuidString, $0.value) })
        try enc.encode(map).write(to: url, options: .atomic)
    }
}
