import XCTest
import os
@testable import TranscriberCore

final class LoggingTests: XCTestCase {
    func testSubsystemIsBundleStyle() {
        XCTAssertEqual(Log.subsystem, "com.szymonsypniewicz.transcriber")
    }

    func testCategoriesEnumerated() {
        let expected: Set<String> = [
            "lifecycle", "capture", "engine", "calendar",
            "permissions", "storage", "diagnostics"
        ]
        XCTAssertEqual(Set(Log.categories), expected)
    }

    func testEachCategoryHasLogger() {
        XCTAssertNotNil(Log.lifecycle)
        XCTAssertNotNil(Log.capture)
        XCTAssertNotNil(Log.engine)
        XCTAssertNotNil(Log.calendar)
        XCTAssertNotNil(Log.permissions)
        XCTAssertNotNil(Log.storage)
        XCTAssertNotNil(Log.diagnostics)
    }
}
