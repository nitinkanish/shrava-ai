import XCTest
@testable import ShravaCore

final class URLIntentRouterTests: XCTestCase {
    func testRecordAndLive() {
        XCTAssertEqual(URLIntentRouter.parse(URL(string: "shrava://record")!), .record)
        XCTAssertEqual(URLIntentRouter.parse(URL(string: "shrava://live")!), .liveActivity)
        XCTAssertEqual(URLIntentRouter.parse(URL(string: "shrava://recording")!), .liveActivity)
    }

    func testHistoryWithID() {
        let id = UUID()
        let url = URL(string: "shrava://history/\(id.uuidString)")!
        XCTAssertEqual(URLIntentRouter.parse(url), .history(id))
    }

    func testDebugAndTabs() {
        XCTAssertEqual(URLIntentRouter.parse(URL(string: "shrava://debug/long")!), .debug("long"))
        XCTAssertEqual(URLIntentRouter.parse(URL(string: "shrava://tab/settings")!), .tab("settings"))
        XCTAssertEqual(URLIntentRouter.parse(URL(string: "shrava://settings")!), .settings)
    }

    func testNonShravaNil() {
        XCTAssertNil(URLIntentRouter.parse(URL(string: "https://example.com")!))
    }
}
