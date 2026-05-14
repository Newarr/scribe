import XCTest
@testable import TranscriberCore

final class ProcessWatcherTests: XCTestCase {
    func testMeetingAppsFromRunningBundleIDsIncludesNativeAppsAndBrowsers() {
        let apps = ProcessWatcher.meetingApps(from: [
            "com.apple.finder",
            "com.google.Chrome",
            "us.zoom.xos",
            "com.google.Chrome",
            "org.mozilla.firefox"
        ])

        XCTAssertEqual(apps.map(\.bundleID), [
            "com.google.Chrome",
            "us.zoom.xos",
            "org.mozilla.firefox"
        ], "running-app scans must re-evaluate supported browsers and native apps once each")
    }

    func testMeetingAppsFromRunningBundleIDsDoesNotIncludeHelpersOrUnsupportedApps() {
        let apps = ProcessWatcher.meetingApps(from: [
            "com.google.Chrome.helper.renderer",
            "com.apple.WebKit.Networking",
            "com.apple.FaceTime"
        ])

        XCTAssertEqual(apps.map(\.bundleID), ["com.apple.FaceTime"], "ProcessWatcher should scan top-level running apps while CoreAudioInputProbe handles helper process bundle matching")
    }
}
