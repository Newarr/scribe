import Foundation

public struct MeetingApp: Sendable, Equatable, Hashable {
    public let bundleID: String
    public let displayName: String

    public init(bundleID: String, displayName: String) {
        self.bundleID = bundleID
        self.displayName = displayName
    }
}

/// V1 allowlist (spec lines 61-69). One file, one PR per contribution
/// (`decision_allowlist_single_source`). Adding an app is a single entry.
public enum MeetingApps {
    public static let allowlist: [MeetingApp] = [
        // Native meeting apps
        .init(bundleID: "us.zoom.xos", displayName: "Zoom"),
        .init(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams"),
        .init(bundleID: "com.microsoft.teams", displayName: "Microsoft Teams (legacy)"),
        .init(bundleID: "org.whispersystems.signal-desktop", displayName: "Signal"),
        // Browsers (any tab; per-URL detection deferred per slice 5 light scope)
        .init(bundleID: "com.google.Chrome", displayName: "Chrome"),
        .init(bundleID: "com.apple.Safari", displayName: "Safari"),
        .init(bundleID: "company.thebrowser.Browser", displayName: "Arc"),
        .init(bundleID: "com.microsoft.Edge", displayName: "Edge"),
        .init(bundleID: "org.mozilla.firefox", displayName: "Firefox"),
        .init(bundleID: "com.brave.Browser", displayName: "Brave"),
        .init(bundleID: "im.helium.helium", displayName: "Helium"),
    ]

    public static func appFor(bundleID: String) -> MeetingApp? {
        allowlist.first(where: { $0.bundleID == bundleID })
    }
}
