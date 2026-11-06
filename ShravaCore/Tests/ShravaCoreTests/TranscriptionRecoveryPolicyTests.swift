import XCTest
@testable import ShravaCore

final class TranscriptionRecoveryPolicyTests: XCTestCase {
    func testPhoneMemoryBoundedForTwoHourMeeting() {
        let ranges = TranscriptChunkScheduler.overlappingFrameRanges(
            totalFrames: 44_100 * 7_200, sampleRate: 44_100,
            windowSeconds: TranscriptionRecoveryPolicy.iosWindowSeconds,
            overlapSeconds: TranscriptionRecoveryPolicy.iosOverlapSeconds)
        XCTAssertEqual(ranges.first?.start, 0)
        XCTAssertEqual(ranges.last.map { $0.start + $0.count }, 44_100 * 7_200)
        XCTAssertTrue(ranges.allSatisfy { $0.count <= 44_100 * 60 })
    }
    func testInterruptedPendingBecomesRetryableAndKeepsAudio() {
        let e = HistoryEntry(originalText: "Transcribing…", cleanedText: "Transcribing…", language: "auto", durationSeconds: 659, transcriptionState: .pending, audioFileName: "meeting.m4a", transcriptionProgress: 0.5)
        let fixed = TranscriptionRecoveryPolicy.interruptedEntry(e)
        XCTAssertEqual(fixed.transcriptionState, .failed)
        XCTAssertEqual(fixed.audioFileName, e.audioFileName)
        XCTAssertNotNil(fixed.transcriptionError)
        XCTAssertTrue(fixed.isPlaceholderTranscript)
    }
    func testInterruptedRegeneratePreservesPriorTextAndTimestamp() {
        let e = HistoryEntry(originalText: "Previous transcript", cleanedText: "Previous transcript", language: "hi", durationSeconds: 900, transcriptionState: .pending, audioFileName: "meeting.m4a")
        let fixed = TranscriptionRecoveryPolicy.interruptedEntry(e)
        XCTAssertEqual(fixed.transcriptionState, .partial)
        XCTAssertEqual(fixed.cleanedText, e.cleanedText)
        XCTAssertEqual(fixed.timestamp, e.timestamp)
    }
    func testUnstartedOrphanIsNotAnError() {
        let e = HistoryEntry(originalText: "Recovered recording", cleanedText: "Recovered recording — tap to transcribe", language: "auto", durationSeconds: 900, transcriptionState: .pending, audioFileName: "meeting.m4a", transcriptionProgress: 0)
        XCTAssertEqual(TranscriptionRecoveryPolicy.interruptedEntry(e), e)
    }
    func testCheckpointCannotSkipFailedWindowOrChangeSettings() throws {
        var cp = TranscriptCheckpoint(fingerprint: "turbo|auto|60|5")
        cp.finishWindow(text: "hello")
        cp.finishWindow(text: "") // genuine silent window
        XCTAssertTrue(cp.canResume(fingerprint: cp.fingerprint, windowCount: 3))
        XCTAssertFalse(cp.canResume(fingerprint: "turbo|hi|60|5", windowCount: 3))
        cp.nextWindow += 1 // failed/unsaved window must never be considered complete
        XCTAssertFalse(cp.canResume(fingerprint: cp.fingerprint, windowCount: 3))
    }
    func testAutoUsesActualWindowDetectionRatherThanAlwaysHindi() {
        XCTAssertEqual(TranscriptionRecoveryPolicy.languageForWindow(requested: .auto, detected: .english), .english)
        XCTAssertEqual(TranscriptionRecoveryPolicy.languageForWindow(requested: .auto, detected: .hindi), .hindi)
        XCTAssertEqual(TranscriptionRecoveryPolicy.languageForWindow(requested: .hindi, detected: .english), .hindi)
        XCTAssertEqual(TranscriptionRecoveryPolicy.languageForWindow(requested: .english, detected: .hindi), .english)
    }
    func testModelDownloadRejectsTruncatedOrOversizedResponse() {
        XCTAssertTrue(TranscriptionRecoveryPolicy.validModelByteCount(574_041_195, expected: 574_041_195))
        XCTAssertFalse(TranscriptionRecoveryPolicy.validModelByteCount(400_000_000, expected: 574_041_195))
        XCTAssertFalse(TranscriptionRecoveryPolicy.validModelByteCount(800_000_000, expected: 574_041_195))
    }
    func testErrorMetadataRoundTripsAndOldHistoryDecodes() throws {
        let e = HistoryEntry(originalText: "Kept text", cleanedText: "Kept text", language: "auto", durationSeconds: 10, transcriptionError: "Interrupted")
        let data = try JSONEncoder().encode(e)
        XCTAssertEqual(try JSONDecoder().decode(HistoryEntry.self, from: data), e)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "transcriptionError")
        XCTAssertNil(try JSONDecoder().decode(HistoryEntry.self, from: JSONSerialization.data(withJSONObject: json)).transcriptionError)
    }
}
