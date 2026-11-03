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
}
