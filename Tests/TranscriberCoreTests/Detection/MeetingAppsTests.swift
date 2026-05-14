import XCTest
@testable import TranscriberCore

final class MeetingAppsTests: XCTestCase {
    func testKnownAppIsLookedUp() {
        let zoom = MeetingApps.appFor(bundleID: "us.zoom.xos")
        XCTAssertNotNil(zoom)
        XCTAssertEqual(zoom?.displayName, "Zoom")
    }

    func testUnknownAppMisses() {
        XCTAssertNil(MeetingApps.appFor(bundleID: "com.example.notallowed"))
    }

    func testAllowlistCoversV1Spec() {
        // Spec lines 64-69: native + browsers. At least these bundle IDs must be present.
        let required: [String] = [
            "us.zoom.xos",
            "com.microsoft.teams2",
            "org.whispersystems.signal-desktop",
            "com.apple.FaceTime",
            "com.google.Chrome",
            "com.apple.Safari",
            "com.microsoft.Edge",
            "org.mozilla.firefox",
            "com.brave.Browser",
            "company.thebrowser.Browser", // Arc
        ]
        for id in required {
            XCTAssertNotNil(MeetingApps.appFor(bundleID: id), "missing required allowlist entry for \(id)")
        }
    }

    func testAllowlistHasTwelveSpecEntriesIncludingFaceTime() {
        XCTAssertEqual(MeetingApps.allowlist.count, 12)
        let faceTime = MeetingApps.appFor(bundleID: "com.apple.FaceTime")
        XCTAssertEqual(faceTime?.displayName, "FaceTime")
        XCTAssertEqual(faceTime?.kind, .nativeMeetingApp)
    }

    func testAllowlistEntriesAreUnique() {
        let ids = MeetingApps.allowlist.map(\.bundleID)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate bundle IDs in allowlist")
    }
}
