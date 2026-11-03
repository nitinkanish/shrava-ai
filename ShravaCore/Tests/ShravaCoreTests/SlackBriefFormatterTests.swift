import XCTest
@testable import ShravaCore

final class SlackBriefFormatterTests: XCTestCase {
    func testPayloadHasHeaderAndFooter() {
        let brief = MeetingBrief(
            meetingType: .planning,
            summary: "We planned the launch.",
            keyPoints: ["Ship Slack integration"],
            decisions: ["Use bot token"],
            ideas: [],
            openQuestions: ["Which channel?"],
            actionItems: [
                MeetingActionItem(task: "Write docs", owner: "Nitin", dueDate: "Friday", priority: "high")
            ],
            model: "gpt-oss:120b-cloud"
        )
        let payload = SlackBriefFormatter.makePayload(
            brief: brief,
            title: "Weekly Planning",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 125
        )
        XCTAssertTrue(payload.text.contains("Weekly Planning"))
        XCTAssertLessThanOrEqual(payload.blocks.count, 50)
        let types = payload.blocks.compactMap { $0["type"] as? String }
        XCTAssertEqual(types.first, "header")
        XCTAssertEqual(types.last, "context")
        let encoded = try! JSONSerialization.data(withJSONObject: payload.blocks)
        XCTAssertFalse(encoded.isEmpty)
    }

    func testTranscriptChunks() {
        let long = String(repeating: "word ", count: 1000)
        let chunks = SlackBriefFormatter.transcriptChunks(long, maxChars: 200)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 200 })
    }
}
