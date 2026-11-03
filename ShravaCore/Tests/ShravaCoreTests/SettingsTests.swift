import XCTest
@testable import ShravaCore

final class SettingsTests: XCTestCase {
    
    func testDefaultSettings() {
        let settings = AppSettings.default
        
        XCTAssertEqual(settings.language, .english)
        XCTAssertFalse(settings.iCloudSyncEnabled)
        XCTAssertTrue(settings.autoCleanup)
        XCTAssertFalse(settings.showOriginalText)
        XCTAssertTrue(settings.hapticFeedback)
        XCTAssertTrue(settings.soundFeedback)
    }
    
    func testSupportedLanguages() {
        XCTAssertEqual(SupportedLanguage.english.rawValue, "en")
        XCTAssertEqual(SupportedLanguage.spanish.rawValue, "es")
        XCTAssertEqual(SupportedLanguage.french.rawValue, "fr")
        XCTAssertEqual(SupportedLanguage.german.rawValue, "de")
        XCTAssertEqual(SupportedLanguage.japanese.rawValue, "ja")
        XCTAssertEqual(SupportedLanguage.chinese.rawValue, "zh")
    }
    
    func testLanguageDisplayNames() {
        XCTAssertEqual(SupportedLanguage.english.displayName, "English")
        XCTAssertEqual(SupportedLanguage.spanish.displayName, "Spanish")
        XCTAssertEqual(SupportedLanguage.french.displayName, "French")
        XCTAssertEqual(SupportedLanguage.german.displayName, "German")
        XCTAssertEqual(SupportedLanguage.japanese.displayName, "Japanese")
        XCTAssertEqual(SupportedLanguage.chinese.displayName, "Chinese")
    }
    
    func testAllLanguagesCovered() {
        for language in SupportedLanguage.allCases {
            XCTAssertFalse(language.rawValue.isEmpty, "\(language) should have a raw value")
            XCTAssertFalse(language.displayName.isEmpty, "\(language) should have a display name")
        }
    }
    
    func testSettingsCodable() throws {
        let settings = AppSettings(
            language: .spanish,
            iCloudSyncEnabled: true,
            autoCleanup: false,
            showOriginalText: true,
            hapticFeedback: false,
            soundFeedback: false
        )
        
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        
        XCTAssertEqual(decoded.language, .spanish)
        XCTAssertTrue(decoded.iCloudSyncEnabled)
        XCTAssertFalse(decoded.autoCleanup)
        XCTAssertTrue(decoded.showOriginalText)
        XCTAssertFalse(decoded.hapticFeedback)
        XCTAssertFalse(decoded.soundFeedback)
    }
}
