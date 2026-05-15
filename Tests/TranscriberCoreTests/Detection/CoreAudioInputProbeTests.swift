import XCTest
@testable import TranscriberCore

final class CoreAudioInputProbeTests: XCTestCase {
    func testExactBundleMatch() {
        XCTAssertTrue(CoreAudioInputProbe.matches(
            allowlistBundle: "us.zoom.xos",
            processBundle: "us.zoom.xos"
        ))
    }

    func testHelperBundleMatchesParent() {
        // The actual bug Codex caught: Chrome's mic-holding process
        // bundle is a helper, not the parent. Without prefix matching
        // every real Chrome/Meet call is invisible to the probe.
        XCTAssertTrue(CoreAudioInputProbe.matches(
            allowlistBundle: "com.google.Chrome",
            processBundle: "com.google.Chrome.helper.renderer"
        ))
        XCTAssertTrue(CoreAudioInputProbe.matches(
            allowlistBundle: "org.whispersystems.signal-desktop",
            processBundle: "org.whispersystems.signal-desktop.helper.Renderer"
        ))
        XCTAssertTrue(CoreAudioInputProbe.matches(
            allowlistBundle: "net.imput.helium",
            processBundle: "net.imput.helium.helper.renderer"
        ))
        XCTAssertTrue(CoreAudioInputProbe.matches(
            allowlistBundle: "net.imput.helium",
            processBundle: "net.imput.helium.helper.GPU"
        ))
    }

    func testSiblingBundleDoesNotMatch() {
        // "com.google.ChromeHelper" must NOT match "com.google.Chrome"
        // — the prefix rule requires a dotted child, not a string-prefix
        // sibling, otherwise a third-party app could spoof the namespace.
        XCTAssertFalse(CoreAudioInputProbe.matches(
            allowlistBundle: "com.google.Chrome",
            processBundle: "com.google.ChromeHelper"
        ))
        XCTAssertFalse(CoreAudioInputProbe.matches(
            allowlistBundle: "net.imput.helium",
            processBundle: "net.imput.heliumHelper"
        ))
    }

    func testUnrelatedBundleDoesNotMatch() {
        XCTAssertFalse(CoreAudioInputProbe.matches(
            allowlistBundle: "us.zoom.xos",
            processBundle: "com.apple.WebKit.Networking"
        ))
    }

    func testEmptyBundleDoesNotMatch() {
        XCTAssertFalse(CoreAudioInputProbe.matches(
            allowlistBundle: "us.zoom.xos",
            processBundle: ""
        ))
    }
}
