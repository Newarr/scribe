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

    // MARK: - dialects live on the allowlist

    func testEveryAllowlistedBrowserHasADialectOrExplicitNone() {
        for app in MeetingApps.allowlist {
            switch app.kind {
            case .nativeMeetingApp:
                XCTAssertEqual(app.tabDialect, .none, "native apps never inspect tabs")
            case .browser:
                if app.bundleID == "org.mozilla.firefox" {
                    XCTAssertEqual(app.tabDialect, .none, "Firefox has no AppleScript tab access")
                } else {
                    XCTAssertNotEqual(
                        app.tabDialect, .none, "\(app.bundleID) must declare a tab dialect")
                }
            }
        }
    }

    func testScriptComesFromTheDialect() {
        XCTAssertNil(
            BrowserTabInspector.script(for: MeetingApp(
                bundleID: "org.mozilla.firefox", displayName: "Firefox", kind: .browser)))
        XCTAssertNotNil(
            BrowserTabInspector.script(
                for: MeetingApps.appFor(bundleID: "com.apple.Safari")))
        XCTAssertNotNil(
            BrowserTabInspector.script(
                for: MeetingApps.appFor(bundleID: "net.imput.helium")))
        // An unknown bundle ID has no allowlist entry and no dialect.
        XCTAssertNil(
            BrowserTabInspector.script(
                for: MeetingApps.appFor(bundleID: "com.unknown.browser")))
    }

    // MARK: - inspection outcomes

    func testMatchingTabIsMeeting() async {
        let inspector = BrowserTabInspector(timeout: 2) { _ in
            "https://meet.google.com/abc\nWeekly sync"
        }
        let result = await inspector.inspectActiveTab(bundleID: "net.imput.helium")
        XCTAssertEqual(result, .meeting)
    }

    func testNonMeetingTabIsNotMeeting() async {
        let inspector = BrowserTabInspector(timeout: 2) { _ in
            "https://www.youtube.com/watch?v=x\nSome video"
        }
        let result = await inspector.inspectActiveTab(bundleID: "com.google.Chrome")
        XCTAssertEqual(result, .notMeeting)
    }

    func testScriptErrorIsUnreadable() async {
        // Grant denial and script failure both surface as a thrown error.
        let inspector = BrowserTabInspector(timeout: 2) { _ in
            throw BrowserTabInspector.InspectionError.scriptFailed
        }
        let result = await inspector.inspectActiveTab(bundleID: "com.apple.Safari")
        XCTAssertEqual(result, .unreadable)
    }

    func testFirefoxIsUnreadableWithoutRunningAnyScript() async {
        let called = Mutex(false)
        let inspector = BrowserTabInspector(timeout: 2) { _ in
            called.withLock { $0 = true }
            return "https://meet.google.com/abc\nx"
        }
        let result = await inspector.inspectActiveTab(bundleID: "org.mozilla.firefox")
        XCTAssertEqual(result, .unreadable)
        XCTAssertFalse(called.withLock { $0 })
    }

    func testHungScriptIsUnreadableWithinTimeout() async {
        // A hanging AppleEvent must cancel, never abandon, and never
        // stall the caller past the hard timeout.
        let inspector = BrowserTabInspector(timeout: 0.2) { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return "https://meet.google.com/abc\nx"
        }
        let started = Date()
        let result = await inspector.inspectActiveTab(bundleID: "net.imput.helium")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(result, .unreadable)
        XCTAssertLessThan(elapsed, 2, "inspection must resolve well inside the 2s dwell budget")
    }
}
