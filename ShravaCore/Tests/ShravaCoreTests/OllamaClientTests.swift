import XCTest
@testable import ShravaCore

final class OllamaClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testDecodeMeetingBriefFromChatResponse() async throws {
        let briefJSON = """
        {"meeting_type":"planning","summary":"Ship it","key_points":["A"],"decisions":[],"ideas":[],"open_questions":[],"action_items":[]}
        """
        let envelope: [String: Any] = [
            "message": ["role": "assistant", "content": briefJSON],
            "done": true
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        MockURLProtocol.requestHandler = { req in
            XCTAssertTrue(req.url?.absoluteString.contains("api/chat") == true)
            let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, data)
        }
        let client = OllamaClient(session: MockURLSessionFactory.make())
        // Force local mode so no API key is required.
        let settings = AnalysisSettings(endpointMode: .local, customBaseURL: "http://localhost:11434", model: "test", maxCharsPerRequest: 48_000)
        // Temporarily analyze via reflection of settings on instance — set through store
        AnalysisSettingsStore.save(settings)
        let brief = try await client.analyzeMeeting(transcript: "We will ship the feature Friday.")
        XCTAssertEqual(brief.summary, "Ship it")
        XCTAssertEqual(brief.keyPoints.first, "A")
    }

    func testHTTPErrorSurfaced() async {
        MockURLProtocol.requestHandler = { req in
            let res = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (res, Data("unauthorized".utf8))
        }
        AnalysisSettingsStore.save(AnalysisSettings(endpointMode: .local, customBaseURL: "http://localhost:11434", model: "test", maxCharsPerRequest: 1000))
        let client = OllamaClient(session: MockURLSessionFactory.make())
        do {
            _ = try await client.analyzeMeeting(transcript: "hello world meeting notes")
            XCTFail("expected throw")
        } catch let err as OllamaError {
            if case .httpStatus(let code, _) = err {
                XCTAssertEqual(code, 401)
            } else {
                XCTFail("wrong error \(err)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
