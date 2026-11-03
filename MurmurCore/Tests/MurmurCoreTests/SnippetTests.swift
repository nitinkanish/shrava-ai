import XCTest
@testable import MurmurCore

final class SnippetTests: XCTestCase {
    
    func testAddSnippet() async {
        let manager = SnippetManager()
        
        let snippet = Snippet(trigger: "sig", content: "Best regards,\nJohn Doe")
        await manager.add(snippet)
        
        let snippets = await manager.getAll()
        
        XCTAssertEqual(snippets.count, 1)
        XCTAssertEqual(snippets.first?.trigger, "sig")
        XCTAssertEqual(snippets.first?.content, "Best regards,\nJohn Doe")
    }
    
    func testFindByTrigger() async {
        let manager = SnippetManager()
        
        await manager.add(Snippet(trigger: "sig", content: "Signature"))
        await manager.add(Snippet(trigger: "addr", content: "123 Main St"))
        
        let found = await manager.find(byTrigger: "sig")
        
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.content, "Signature")
    }
    
    func testFindByTriggerCaseInsensitive() async {
        let manager = SnippetManager()
        
        await manager.add(Snippet(trigger: "SIG", content: "Signature"))
        
        let found = await manager.find(byTrigger: "sig")
        
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.content, "Signature")
    }
    
    func testFindByTriggerReturnsNilForDisabled() async {
        let manager = SnippetManager()
        
        await manager.add(Snippet(trigger: "sig", content: "Signature", isEnabled: false))
        
        let found = await manager.find(byTrigger: "sig")
        
        XCTAssertNil(found)
    }
    
    func testToggleSnippet() async {
        let manager = SnippetManager()
        
        let snippet = Snippet(trigger: "sig", content: "Signature", isEnabled: true)
        await manager.add(snippet)
        
        let toggled = snippet.toggled()
        await manager.update(toggled)
        
        let snippets = await manager.getAll()
        
        XCTAssertEqual(snippets.first?.isEnabled, false)
    }
    
    func testDeleteSnippet() async {
        let manager = SnippetManager()
        
        let snippet = Snippet(trigger: "sig", content: "Signature")
        await manager.add(snippet)
        await manager.delete(snippet.id)
        
        let snippets = await manager.getAll()
        
        XCTAssertEqual(snippets.count, 0)
    }
    
    func testAddDuplicateTrigger() async {
        let manager = SnippetManager()
        
        await manager.add(Snippet(trigger: "sig", content: "Signature 1"))
        await manager.add(Snippet(trigger: "sig", content: "Signature 2"))
        
        let snippets = await manager.getAll()
        
        XCTAssertEqual(snippets.count, 1, "Should not add duplicate triggers")
        XCTAssertEqual(snippets.first?.content, "Signature 1")
    }
    
    func testSnippetCodable() throws {
        let snippet = Snippet(
            trigger: "test",
            content: "Test content",
            isEnabled: true
        )
        
        let encoded = try JSONEncoder().encode(snippet)
        let decoded = try JSONDecoder().decode(Snippet.self, from: encoded)
        
        XCTAssertEqual(decoded.trigger, snippet.trigger)
        XCTAssertEqual(decoded.content, snippet.content)
        XCTAssertEqual(decoded.isEnabled, snippet.isEnabled)
    }
}
