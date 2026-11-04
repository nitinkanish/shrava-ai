import XCTest
@testable import ShravaCore

final class WhisperLanguageSupportTests: XCTestCase {

    func testResolveAutoPrefersHindiWhenClose() {
        XCTAssertEqual(
            WhisperLanguageSupport.resolveAuto(detectedCode: "en", enProbability: 0.52, hiProbability: 0.48),
            .hindi
        )
        XCTAssertEqual(
            WhisperLanguageSupport.resolveAuto(detectedCode: "hi", enProbability: 0.45, hiProbability: 0.55),
            .hindi
        )
    }

    func testResolveAutoPicksClearEnglish() {
        XCTAssertEqual(
            WhisperLanguageSupport.resolveAuto(detectedCode: "en", enProbability: 0.9, hiProbability: 0.1),
            .english
        )
    }

    func testResolveAutoFromCodeAlone() {
        XCTAssertEqual(WhisperLanguageSupport.resolveAuto(detectedCode: "hi"), .hindi)
        XCTAssertEqual(WhisperLanguageSupport.resolveAuto(detectedCode: "en"), .english)
        XCTAssertEqual(WhisperLanguageSupport.resolveAuto(detectedCode: nil), .hindi)
        XCTAssertEqual(WhisperLanguageSupport.resolveAuto(detectedCode: "ur"), .hindi)
    }

    func testParseDetectedLanguageFromCLI() {
        let sample = "whisper_full_with_state: auto-detected language: en (p = 0.545246)"
        let parsed = WhisperLanguageSupport.parseDetectedLanguage(from: sample)
        XCTAssertEqual(parsed?.code, "en")
        XCTAssertEqual(parsed?.probability ?? 0, 0.545246, accuracy: 0.0001)

        let hi = WhisperLanguageSupport.parseDetectedLanguage(
            from: "auto-detected language: hi (p = 0.812)"
        )
        XCTAssertEqual(hi?.code, "hi")
        XCTAssertEqual(hi?.probability ?? 0, 0.812, accuracy: 0.001)
    }

    func testFilterHallucinationsDropsForeignLanguagePlaceholders() {
        let raw = """
        (Speaking in foreign language)
        Hello team
        [foreign language]
        हम मिलेंगे
        """
        let filtered = WhisperLanguageSupport.filterHallucinations(raw)
        XCTAssertFalse(filtered.lowercased().contains("foreign"))
        XCTAssertTrue(filtered.contains("Hello team"))
        XCTAssertTrue(filtered.contains("हम मिलेंगे"))
    }

    func testIsMostlyPlaceholders() {
        XCTAssertTrue(WhisperLanguageSupport.isMostlyPlaceholders("(Speaking in foreign language)"))
        XCTAssertTrue(WhisperLanguageSupport.isMostlyPlaceholders("[foreign language]"))
        XCTAssertFalse(WhisperLanguageSupport.isMostlyPlaceholders("Let's schedule the standup for Monday."))
    }

    func testNeedsRetryWhenTooShortForDuration() {
        // 72s recording with ~131 placeholder chars → retry
        let bad = "(Speaking in foreign language) [foreign language]"
        XCTAssertTrue(WhisperLanguageSupport.needsRetry(text: bad, durationSeconds: 72))
        let good = String(repeating: "meeting notes about the roadmap and hiring plan. ", count: 8)
        XCTAssertFalse(WhisperLanguageSupport.needsRetry(text: good, durationSeconds: 72))
    }

    func testOtherAutoLanguage() {
        XCTAssertEqual(WhisperLanguageSupport.otherAutoLanguage(than: .hindi), .english)
        XCTAssertEqual(WhisperLanguageSupport.otherAutoLanguage(than: .english), .hindi)
    }

    func testWhisperCode() {
        XCTAssertEqual(WhisperLanguageSupport.whisperCode(for: .auto), "auto")
        XCTAssertEqual(WhisperLanguageSupport.whisperCode(for: .english), "en")
        XCTAssertEqual(WhisperLanguageSupport.whisperCode(for: .hindi), "hi")
    }

    func testContainsDevanagari() {
        XCTAssertTrue(WhisperLanguageSupport.containsDevanagari("नमस्ते team"))
        XCTAssertFalse(WhisperLanguageSupport.containsDevanagari("Hello team"))
    }

    func testLikelyDroppedHindiSpans() {
        XCTAssertTrue(
            WhisperLanguageSupport.likelyDroppedHindiSpans(
                text: "Hello team today we discuss the budget and timeline thank you",
                durationSeconds: 20,
                resolved: .hindi
            )
        )
        XCTAssertFalse(
            WhisperLanguageSupport.likelyDroppedHindiSpans(
                text: "नमस्ते team आज budget discuss",
                durationSeconds: 20,
                resolved: .hindi
            )
        )
        XCTAssertFalse(
            WhisperLanguageSupport.likelyDroppedHindiSpans(
                text: "Hello only english",
                durationSeconds: 20,
                resolved: .english
            )
        )
    }
}
