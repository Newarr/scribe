import XCTest
@testable import TranscriberCore

final class KeychainStoreTests: XCTestCase {
    let service = "com.szymonsypniewicz.transcriber.test"
    let account = "test-account-\(UUID().uuidString)"

    override func tearDown() {
        try? KeychainStore(service: service, account: account).delete()
    }

    func testSetReadDelete() throws {
        let store = KeychainStore(service: service, account: account)
        XCTAssertNil(try store.read())

        try store.write("super-secret-value")
        XCTAssertEqual(try store.read(), "super-secret-value")

        try store.write("updated-value")
        XCTAssertEqual(try store.read(), "updated-value")

        try store.delete()
        XCTAssertNil(try store.read())
    }
}
