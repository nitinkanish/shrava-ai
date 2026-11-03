import XCTest
@testable import ShravaCore

final class HistoryPersistenceTests: XCTestCase {
    func testAtomicPersistenceAndPartialMigration() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let manager = HistoryManager(maxEntries: 50, storageURL: url)
        // Give load task a beat
        try await Task.sleep(nanoseconds: 50_000_000)

        let entry = HistoryEntry(
            originalText: "hi",
            cleanedText: "Hi",
            language: "en",
            durationSeconds: 1,
            transcriptionState: .partial,
            audioFileName: "a.m4a",
            transcriptionProgress: 0.4
        )
        await manager.add(entry)
        try await Task.sleep(nanoseconds: 80_000_000)

        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([HistoryEntry].self, from: data)
        XCTAssertEqual(decoded.first?.transcriptionState, .partial)

        // Legacy entry without state decodes as complete
        // Use ISO8601-ish via JSONEncoder path instead
        struct Legacy: Codable {
            let id: UUID
            let originalText: String
            let cleanedText: String
            let language: String
            let timestamp: Date
            let durationSeconds: Double
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .deferredToDate
        let legacyData = try enc.encode([Legacy(id: UUID(), originalText: "o", cleanedText: "c", language: "en", timestamp: Date(), durationSeconds: 2)])
        try legacyData.write(to: url, options: .atomic)

        let manager2 = HistoryManager(maxEntries: 50, storageURL: url)
        try await Task.sleep(nanoseconds: 80_000_000)
        let all = await manager2.getAll()
        XCTAssertEqual(all.first?.transcriptionState, .complete)
        _ = entry
    }

    func testBriefStoreRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("briefs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = BriefStore(storageURL: url)
        let id = UUID()
        let brief = MeetingBrief(
            meetingType: .planning,
            summary: "Plan",
            keyPoints: ["One"],
            decisions: [],
            ideas: [],
            openQuestions: [],
            actionItems: [],
            model: "test"
        )
        try await store.save(brief, for: id)
        let loaded = await store.brief(for: id)
        XCTAssertEqual(loaded?.summary, "Plan")
    }
}
