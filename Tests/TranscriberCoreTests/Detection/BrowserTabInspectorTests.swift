import Synchronization
import XCTest

@testable import TranscriberCore

final class BrowserTabInspectorTests: XCTestCase {
    // MARK: - domain matching

    func testMeetURLMatches() {
        XCTAssertTrue(
            BrowserTabInspector.matchesMeetingDomain(
                url: "https://meet.google.com/abc-defg-hij", title: "Weekly sync"))
    }

    func testZoomSubdomainMatches() {
        XCTAssertTrue(
            BrowserTabInspector.matchesMeetingDomain(
                url: "https://us02web.zoom.us/j/123456", title: ""))
    }

    func testLookalikeHostDoesNotMatch() {
        // "notzoom.us" is neither the domain nor a dotted subdomain of it.
        XCTAssertFalse(
            BrowserTabInspector.matchesMeetingDomain(url: "https://notzoom.us/j/1", title: ""))
    }

    func testYouTubeDoesNotMatch() {
        XCTAssertFalse(
            BrowserTabInspector.matchesMeetingDomain(
                url: "https://www.youtube.com/watch?v=x", title: "Some video"))
    }

    func testTitleMatchesWhenURLDoesNot() {
        XCTAssertTrue(
            BrowserTabInspector.matchesMeetingDomain(
                url: "about:blank", title: "Acme standup - meet.google.com"))
    }

    func testTeamsDomainsMatch() {
        XCTAssertTrue(
            BrowserTabInspector.matchesMeetingDomain(
                url: "https://teams.microsoft.com/l/meetup", title: ""))
        XCTAssertTrue(
            BrowserTabInspector.matchesMeetingDomain(
                url: "https://teams.live.com/meet/9", title: ""))
    }

    // MARK: - script dialects

    func testFirefoxHasNoScript() {
        XCTAssertNil(BrowserTabInspector.script(forBundleID: "org.mozilla.firefox"))
    }

    func testCoveredBrowsersHaveScripts() {
        for bundleID in [
            "com.apple.Safari", "com.google.Chrome", "com.microsoft.Edge",
            "com.brave.Browser", "company.thebrowser.Browser",
            "net.imput.helium", "im.helium.helium",
        ] {
            XCTAssertNotNil(
                BrowserTabInspector.script(forBundleID: bundleID), "missing script for \(bundleID)")
        }
    }

    // MARK: - inspection outcomes

    func testMatchingTabReturnsTrue() async {
        let inspector = BrowserTabInspector(timeout: 2) { _ in
            "https://meet.google.com/abc\nWeekly sync"
        }
        let match = await inspector.activeTabMatchesMeeting(bundleID: "net.imput.helium")
        XCTAssertEqual(match, true)
    }

    func testNonMeetingTabReturnsFalse() async {
        let inspector = BrowserTabInspector(timeout: 2) { _ in
            "https://www.youtube.com/watch?v=x\nSome video"
        }
        let match = await inspector.activeTabMatchesMeeting(bundleID: "com.google.Chrome")
        XCTAssertEqual(match, false)
    }

    func testScriptErrorReturnsNil() async {
        // Grant denial and script failure both surface as a thrown error.
        let inspector = BrowserTabInspector(timeout: 2) { _ in
            throw BrowserTabInspector.InspectionError.scriptFailed
        }
        let match = await inspector.activeTabMatchesMeeting(bundleID: "com.apple.Safari")
        XCTAssertNil(match)
    }

    func testFirefoxReturnsNilWithoutRunningAnyScript() async {
        let called = Mutex(false)
        let inspector = BrowserTabInspector(timeout: 2) { _ in
            called.withLock { $0 = true }
            return "https://meet.google.com/abc\nx"
        }
        let match = await inspector.activeTabMatchesMeeting(bundleID: "org.mozilla.firefox")
        XCTAssertNil(match)
        XCTAssertFalse(called.withLock { $0 })
    }

    func testHungScriptResolvesNilWithinTimeout() async {
        // A hanging AppleEvent must cancel, never abandon, and never
        // stall the caller past the hard timeout.
        let inspector = BrowserTabInspector(timeout: 0.2) { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return "https://meet.google.com/abc\nx"
        }
        let started = Date()
        let match = await inspector.activeTabMatchesMeeting(bundleID: "net.imput.helium")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertNil(match)
        XCTAssertLessThan(elapsed, 2, "inspection must resolve well inside the 2s dwell budget")
    }
}
