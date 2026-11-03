import XCTest
@testable import ShravaCore

final class RecordingStateMachineTests: XCTestCase {
    func testStartPauseResumeStop() {
        var p = RecordingPhase.idle
        p = RecordingStateMachine.reduce(phase: p, event: .start)
        XCTAssertEqual(p, .recording)
        p = RecordingStateMachine.reduce(phase: p, event: .pause)
        XCTAssertEqual(p, .paused)
        p = RecordingStateMachine.reduce(phase: p, event: .resume)
        XCTAssertEqual(p, .recording)
        p = RecordingStateMachine.reduce(phase: p, event: .stop)
        XCTAssertEqual(p, .stopping)
        p = RecordingStateMachine.reduce(phase: p, event: .transcriptionStarted)
        XCTAssertEqual(p, .transcribing)
        p = RecordingStateMachine.reduce(phase: p, event: .transcriptionSucceeded)
        XCTAssertEqual(p, .saved)
    }

    func testInterruptAndCallEnded() {
        var p = RecordingPhase.recording
        p = RecordingStateMachine.reduce(phase: p, event: .interrupt)
        XCTAssertEqual(p, .paused)
        p = RecordingStateMachine.reduce(phase: p, event: .callEnded)
        XCTAssertEqual(p, .recording)
    }

    func testIllegalEventsIgnored() {
        let p = RecordingStateMachine.reduce(phase: .idle, event: .stop)
        XCTAssertEqual(p, .idle)
    }

    func testCanStart() {
        XCTAssertTrue(RecordingStateMachine.canStart(from: .idle))
        XCTAssertFalse(RecordingStateMachine.canStart(from: .recording))
    }
}
