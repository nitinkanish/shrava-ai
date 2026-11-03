import XCTest
@testable import ShravaCore

final class KeychainManagerTests: XCTestCase {
    func testSaveLoadDelete() throws {
        let kc = KeychainManager(service: "com.shrava.tests.\(UUID().uuidString)")
        let key = "unit-test-key"
        try kc.save(key: key, value: "secret-value")
        XCTAssertEqual(try kc.load(key: key), "secret-value")
        try kc.save(key: key, value: "updated")
        XCTAssertEqual(try kc.load(key: key), "updated")
        try kc.delete(key: key)
        XCTAssertThrowsError(try kc.load(key: key))
    }
}
