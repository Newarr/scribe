import Foundation

public struct MeetingApp: Sendable, Equatable, Hashable {
    public let bundleID: String
    public let displayName: String
    /// Native meeting apps are stronger signals than browsers — Zoom or
    /// Teams launching means a call is plausibly starting, while a
    /// browser opening doesn't tell us anything on its own. Used by
    /// `ProcessWatcher` to skip cold-start enumeration of browsers,
    /// which were generating false positives because most users keep a
    /// browser open all day.
    public let kind: Kind
    /// How `BrowserTabInspector` reads this browser's active tab. The
    /// dialect lives here, next to the allowlist entry, so a new
    /// browser ID cannot land in the allowlist and silently take the
    /// calendar-plus-mic fallback: whoever adds the entry picks the
    /// dialect in the same line. Firefox exposes no active tab over
    /// AppleScript and stays `.none`.
    public let tabDialect: TabDialect

    public enum Kind: Sendable, Equatable, Hashable {
        case nativeMeetingApp
        case browser
    }

    public enum TabDialect: Sendable, Equatable, Hashable {
        /// Not scriptable (Firefox) or not a browser. The candidate can
        /// only pass on calendar overlap plus sustained mic.
        case none
        case safari
        case chromium
    }

    init(bundleID: String, displayName: String, kind: Kind, tabDialect: TabDialect = .none) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.kind = kind
        self.tabDialect = tabDialect
    }
}

/// V1 allowlist (spec lines 61-69). One file, one PR per contribution
/// (`decision_allowlist_single_source`). Adding an app is a single entry.
public enum MeetingApps {
    public static let allowlist: [MeetingApp] = [
        // Native meeting apps
        .init(bundleID: "us.zoom.xos",                       displayName: "Zoom",                     kind: .nativeMeetingApp),
        .init(bundleID: "com.microsoft.teams2",              displayName: "Microsoft Teams",          kind: .nativeMeetingApp),
        .init(bundleID: "com.microsoft.teams",               displayName: "Microsoft Teams (legacy)", kind: .nativeMeetingApp),
        .init(bundleID: "org.whispersystems.signal-desktop", displayName: "Signal",                   kind: .nativeMeetingApp),
        .init(bundleID: "com.apple.FaceTime",                 displayName: "FaceTime",                 kind: .nativeMeetingApp),
        // Browsers. The tab gate reads the active tab per dialect;
        // an unreadable tab falls back to calendar plus sustained mic.
        .init(bundleID: "com.google.Chrome",                 displayName: "Chrome",   kind: .browser, tabDialect: .chromium),
        .init(bundleID: "com.apple.Safari",                  displayName: "Safari",   kind: .browser, tabDialect: .safari),
        .init(bundleID: "company.thebrowser.Browser",        displayName: "Arc",      kind: .browser, tabDialect: .chromium),
        .init(bundleID: "com.microsoft.Edge",                displayName: "Edge",     kind: .browser, tabDialect: .chromium),
        .init(bundleID: "org.mozilla.firefox",               displayName: "Firefox",  kind: .browser, tabDialect: .none),
        .init(bundleID: "com.brave.Browser",                 displayName: "Brave",    kind: .browser, tabDialect: .chromium),
        .init(bundleID: "net.imput.helium",                  displayName: "Helium",   kind: .browser, tabDialect: .chromium),
        .init(bundleID: "im.helium.helium",                  displayName: "Helium",   kind: .browser, tabDialect: .chromium),
    ]

    public static func appFor(bundleID: String) -> MeetingApp? {
        allowlist.first(where: { $0.bundleID == bundleID })
    }

    /// V1 meeting-domain list for the browser tab gate. Same
    /// single-source rule as the allowlist: one file, one entry per
    /// addition. `BrowserTabInspector` matches the active tab URL host
    /// (exact or dotted subdomain) and title against these.
    public static let meetingDomains: [String] = [
        "meet.google.com",
        "zoom.us",
        "teams.microsoft.com",
        "teams.live.com",
    ]
}
