import XCTest
@testable import ShravaCore

final class SlackClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testAuthTestParsing() async throws {
        let body: [String: Any] = [
            "ok": true,
            "team": "Debugged",
            "user": "shrava",
            "url": "https://debugged.slack.com/",
            "team_id": "T1",
            "user_id": "U1"
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        MockURLProtocol.requestHandler = { req in
            XCTAssertEqual(req.url?.lastPathComponent, "auth.test")
            let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, data)
        }
        // Inject token via keychain for resolveToken — or pass explicitly
        let client = SlackClient(session: MockURLSessionFactory.make())
        let info = try await client.testAuth(token: "xoxb-test-token")
        XCTAssertEqual(info.team, "Debugged")
        XCTAssertEqual(info.user, "shrava")
    }

    func testFormatterRespectsBlockLimit() {
        let brief = MeetingBrief(
            meetingType: .planning,
            summary: String(repeating: "Summary. ", count: 200),
            keyPoints: (0..<40).map { "Point \($0) " + String(repeating: "x", count: 80) },
            decisions: (0..<20).map { "Decision \($0)" },
            ideas: (0..<20).map { "Idea \($0)" },
            openQuestions: (0..<20).map { "Q \($0)" },
            actionItems: (0..<20).map { MeetingActionItem(task: "Task \($0)", owner: "A", dueDate: nil, priority: "med") },
            model: "test"
        )
        let payload = SlackBriefFormatter.makePayload(brief: brief, title: "Standup", date: Date(), durationSeconds: 600)
        XCTAssertLessThanOrEqual(payload.blocks.count, 50)
    }
}
