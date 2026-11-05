import XCTest
@testable import ShravaCore

final class HistoryEntryDisplayTests: XCTestCase {
    func testRecoveredFailedShowsRecoveredNotFailedBanner() {
        let e = HistoryEntry(
            originalText: "Recovered recording",
            cleanedText: "Recovered recording — tap to transcribe",
            language: "en",
            durationSeconds: 60,
            transcriptionState: .failed
        )
        XCTAssertTrue(e.displayTitle.hasPrefix("Recovered"))
        XCTAssertFalse(e.displayTitle.lowercased().contains("transcription failed"))
    }

    func testPartialShowsBody() {
        let e = HistoryEntry(
            originalText: "hello world",
            cleanedText: "hello world",
            language: "en",
            durationSeconds: 10,
            transcriptionState: .partial
        )
        XCTAssertEqual(e.displayTitle, "hello world")
        XCTAssertTrue(e.isPendingOrFailed)
    }

    func testLongMeetingShortTranscriptNeedsRegenerateCTA() {
        let e = HistoryEntry(
            originalText: "hi",
            cleanedText: "hi there briefly",
            language: "hi",
            durationSeconds: 6965,
            transcriptionState: .complete,
            audioFileName: "meeting.m4a"
        )
        XCTAssertTrue(e.needsTranscriptRegenerateCTA)
    }

    func testCompleteWithAudioStillAllowsRegenerateWithoutForcedCTA() {
        let words = (0..<500).map { "word\($0)" }.joined(separator: " ")
        let e = HistoryEntry(
            originalText: words,
            cleanedText: words,
            language: "en",
            durationSeconds: 120,
            transcriptionState: .complete,
            audioFileName: "short.m4a"
        )
        XCTAssertFalse(e.needsTranscriptRegenerateCTA)
        XCTAssertFalse(e.isPlaceholderTranscript)
    }
}

