import XCTest
@testable import MurmurCore

final class PersonalDictionaryTests: XCTestCase {
    
    func testApplyCorrections() async {
        let dictionary = PersonalDictionary()
        
        await dictionary.add(DictionaryEntry(spoken: "john doe", written: "John Doe"))
        await dictionary.add(DictionaryEntry(spoken: "ai", written: "AI"))
        
        let result = await dictionary.applyCorrections(to: "I spoke with john doe about ai yesterday")
        
        XCTAssertEqual(result, "I spoke with John Doe about AI yesterday")
    }
    
    func testApplyCorrectionsWithDisabledEntry() async {
        let dictionary = PersonalDictionary()
        
        await dictionary.add(DictionaryEntry(spoken: "test", written: "TEST", isEnabled: true))
        await dictionary.add(DictionaryEntry(spoken: "disabled", written: "DISABLED", isEnabled: false))
        
        let result = await dictionary.applyCorrections(to: "This is a test and disabled word")
        
        XCTAssertTrue(result.contains("TEST"), "Enabled entry should be applied")
        XCTAssertFalse(result.contains("DISABLED"), "Disabled entry should not be applied")
    }
    
    func testApplyCorrectionsCaseSensitive() async {
        let dictionary = PersonalDictionary()
        
        await dictionary.add(DictionaryEntry(spoken: "iphone", written: "iPhone"))
        
        let result = await dictionary.applyCorrections(to: "I love my IPHONE and iphone")
        
        XCTAssertTrue(result.contains("iPhone"), "Correction should be case-insensitive")
    }
    
    func testApplyCorrectionsWordBoundary() async {
        let dictionary = PersonalDictionary()
        
        await dictionary.add(DictionaryEntry(spoken: "app", written: "APP"))
        
        let result = await dictionary.applyCorrections(to: "The app is great but application is different")
        
        XCTAssertEqual(result, "The APP is great but application is different", "Should only replace whole words")
    }
    
    func testAddEntry() async {
        let dictionary = PersonalDictionary()
        
        let entry = DictionaryEntry(spoken: "test", written: "TEST")
        await dictionary.add(entry)
        
        let entries = await dictionary.getAll()
        
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.spoken, "test")
        XCTAssertEqual(entries.first?.written, "TEST")
    }
    
    func testAddDuplicateEntry() async {
        let dictionary = PersonalDictionary()
        
        await dictionary.add(DictionaryEntry(spoken: "test", written: "TEST1"))
        await dictionary.add(DictionaryEntry(spoken: "test", written: "TEST2"))
        
        let entries = await dictionary.getAll()
        
        XCTAssertEqual(entries.count, 1, "Should not add duplicate entries with same spoken form")
    }
    
    func testDeleteEntry() async {
        let dictionary = PersonalDictionary()
        
        let entry = DictionaryEntry(spoken: "test", written: "TEST")
        await dictionary.add(entry)
        await dictionary.delete(entry.id)
        
        let entries = await dictionary.getAll()
        
        XCTAssertEqual(entries.count, 0)
    }
    
    func testToggleEntry() async {
        let dictionary = PersonalDictionary()
        
        let entry = DictionaryEntry(spoken: "test", written: "TEST", isEnabled: true)
        await dictionary.add(entry)
        
        let toggled = entry.toggled()
        await dictionary.update(toggled)
        
        let entries = await dictionary.getAll()
        
        XCTAssertEqual(entries.first?.isEnabled, false)
    }
    
    func testGetEnabled() async {
        let dictionary = PersonalDictionary()
        
        await dictionary.add(DictionaryEntry(spoken: "enabled1", written: "E1", isEnabled: true))
        await dictionary.add(DictionaryEntry(spoken: "disabled", written: "D", isEnabled: false))
        await dictionary.add(DictionaryEntry(spoken: "enabled2", written: "E2", isEnabled: true))
        
        let enabled = await dictionary.getEnabled()
        
        XCTAssertEqual(enabled.count, 2)
    }
}
