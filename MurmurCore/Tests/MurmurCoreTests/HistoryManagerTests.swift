import XCTest
@testable import MurmurCore

final class HistoryManagerTests: XCTestCase {
    
    func testAddEntry() async {
        let manager = HistoryManager(maxEntries: 100)
        
        let entry = HistoryEntry(
            originalText: "hello world",
            cleanedText: "Hello, world.",
            language: "en",
            durationSeconds: 2.5
        )
        
        await manager.add(entry)
        let entries = await manager.getAll()
        
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.cleanedText, "Hello, world.")
    }
    
    func testEntriesOrderedByRecent() async {
        let manager = HistoryManager(maxEntries: 100)
        
        let entry1 = HistoryEntry(originalText: "first", cleanedText: "First", language: "en", durationSeconds: 1.0)
        let entry2 = HistoryEntry(originalText: "second", cleanedText: "Second", language: "en", durationSeconds: 1.0)
        
        await manager.add(entry1)
        await manager.add(entry2)
        
        let entries = await manager.getAll()
        
        XCTAssertEqual(entries.first?.cleanedText, "Second", "Most recent entry should be first")
    }
    
    func testMaxEntriesLimit() async {
        let manager = HistoryManager(maxEntries: 3)
        
        for i in 1...5 {
            let entry = HistoryEntry(originalText: "entry\(i)", cleanedText: "Entry \(i)", language: "en", durationSeconds: 1.0)
            await manager.add(entry)
        }
        
        let entries = await manager.getAll()
        
        XCTAssertEqual(entries.count, 3, "Should not exceed max entries")
        XCTAssertEqual(entries.first?.cleanedText, "Entry 5", "Most recent should be first")
        XCTAssertEqual(entries.last?.cleanedText, "Entry 3", "Oldest should be entry 3")
    }
    
    func testGetRecent() async {
        let manager = HistoryManager(maxEntries: 100)
        
        for i in 1...10 {
            let entry = HistoryEntry(originalText: "entry\(i)", cleanedText: "Entry \(i)", language: "en", durationSeconds: 1.0)
            await manager.add(entry)
        }
        
        let recent = await manager.getRecent(limit: 5)
        
        XCTAssertEqual(recent.count, 5)
        XCTAssertEqual(recent.first?.cleanedText, "Entry 10")
    }
    
    func testSearch() async {
        let manager = HistoryManager(maxEntries: 100)
        
        await manager.add(HistoryEntry(originalText: "hello", cleanedText: "Hello there!", language: "en", durationSeconds: 1.0))
        await manager.add(HistoryEntry(originalText: "goodbye", cleanedText: "Goodbye friend", language: "en", durationSeconds: 1.0))
        await manager.add(HistoryEntry(originalText: "hi", cleanedText: "Hi hello", language: "en", durationSeconds: 1.0))
        
        let results = await manager.search(query: "hello")
        
        XCTAssertEqual(results.count, 2, "Should find entries containing 'hello'")
    }
    
    func testSearchCaseInsensitive() async {
        let manager = HistoryManager(maxEntries: 100)
        
        await manager.add(HistoryEntry(originalText: "HELLO", cleanedText: "HELLO WORLD", language: "en", durationSeconds: 1.0))
        
        let results = await manager.search(query: "hello")
        
        XCTAssertEqual(results.count, 1, "Search should be case-insensitive")
    }
    
    func testDeleteEntry() async {
        let manager = HistoryManager(maxEntries: 100)
        
        let entry = HistoryEntry(originalText: "test", cleanedText: "Test", language: "en", durationSeconds: 1.0)
        await manager.add(entry)
        await manager.delete(entry.id)
        
        let entries = await manager.getAll()
        
        XCTAssertEqual(entries.count, 0)
    }
    
    func testClear() async {
        let manager = HistoryManager(maxEntries: 100)
        
        for i in 1...5 {
            let entry = HistoryEntry(originalText: "entry\(i)", cleanedText: "Entry \(i)", language: "en", durationSeconds: 1.0)
            await manager.add(entry)
        }
        
        await manager.clear()
        let entries = await manager.getAll()
        
        XCTAssertEqual(entries.count, 0)
    }
}
