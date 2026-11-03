import XCTest
@testable import ShravaCore

final class CleanupPromptBuilderTests: XCTestCase {
    
    func testBuildSystemPromptContainsLanguage() {
        let builder = CleanupPromptBuilder(language: .english)
        let prompt = builder.buildSystemPrompt()
        
        XCTAssertTrue(prompt.contains("English"), "System prompt should contain the language name")
    }
    
    func testBuildSystemPromptContainsFillerWordRules() {
        let builder = CleanupPromptBuilder(language: .english)
        let prompt = builder.buildSystemPrompt()
        
        XCTAssertTrue(prompt.contains("filler words"), "System prompt should mention filler words")
        XCTAssertTrue(prompt.contains("um"), "System prompt should mention 'um' as a filler word")
        XCTAssertTrue(prompt.contains("uh"), "System prompt should mention 'uh' as a filler word")
    }
    
    func testBuildSystemPromptContainsPunctuationRules() {
        let builder = CleanupPromptBuilder(language: .english)
        let prompt = builder.buildSystemPrompt()
        
        XCTAssertTrue(prompt.contains("punctuation"), "System prompt should mention punctuation")
    }
    
    func testBuildSystemPromptContainsSelfCorrectionRules() {
        let builder = CleanupPromptBuilder(language: .english)
        let prompt = builder.buildSystemPrompt()
        
        XCTAssertTrue(prompt.contains("self-corrections"), "System prompt should mention self-corrections")
    }
    
    func testBuildSystemPromptWithDictionary() {
        let entries = [
            DictionaryEntry(spoken: "john doe", written: "John Doe"),
            DictionaryEntry(spoken: "ai", written: "AI")
        ]
        let builder = CleanupPromptBuilder(language: .english, dictionaryEntries: entries)
        let prompt = builder.buildSystemPrompt()
        
        XCTAssertTrue(prompt.contains("Personal Dictionary"), "System prompt should include dictionary section")
        XCTAssertTrue(prompt.contains("john doe"), "System prompt should include spoken form")
        XCTAssertTrue(prompt.contains("John Doe"), "System prompt should include written form")
    }
    
    func testBuildSystemPromptExcludesDisabledDictionaryEntries() {
        let entries = [
            DictionaryEntry(spoken: "enabled", written: "ENABLED", isEnabled: true),
            DictionaryEntry(spoken: "disabled", written: "DISABLED", isEnabled: false)
        ]
        let builder = CleanupPromptBuilder(language: .english, dictionaryEntries: entries)
        let prompt = builder.buildSystemPrompt()
        
        XCTAssertTrue(prompt.contains("enabled"), "System prompt should include enabled entries")
        XCTAssertFalse(prompt.contains("disabled"), "System prompt should exclude disabled entries")
    }
    
    func testBuildUserPrompt() {
        let builder = CleanupPromptBuilder(language: .english)
        let userPrompt = builder.buildUserPrompt(transcribedText: "Hello world")
        
        XCTAssertTrue(userPrompt.contains("Hello world"), "User prompt should contain the transcribed text")
        XCTAssertTrue(userPrompt.contains("Clean up"), "User prompt should contain cleanup instruction")
    }
    
    func testDifferentLanguages() {
        let languages: [SupportedLanguage] = [.spanish, .french, .german, .japanese]
        
        for language in languages {
            let builder = CleanupPromptBuilder(language: language)
            let prompt = builder.buildSystemPrompt()
            
            XCTAssertTrue(prompt.contains(language.displayName), "System prompt should contain \(language.displayName)")
        }
    }
}
