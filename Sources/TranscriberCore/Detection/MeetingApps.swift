import Foundation

public struct MeetingApp: Sendable, Equatable, Hashable {
    public let bundleID: String
    public let displayName: String
    /// Native meeting apps are stronger signals than browsers — Zoom or
    /// Teams launching means a call is plausibly starting, while a
    /// browser opening doesn't tell us anything (per-URL inspection is
    /// out of scope for V1). Used by `ProcessWatcher` to skip
    /// cold-start enumeration of browsers, which were generating false
    /// positives because most users keep a browser open all day.
    public let kind: Kind

    public enum Kind: Sendable, Equatable, Hashable {
        case nativeMeetingApp
        case browser
    }

    public init(bundleID: String, displayName: String, kind: Kind) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.kind = kind
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
        // Browsers (supported surfaces; per-URL tab inspection deferred, active-call evidence still required when probing can determine it)
        .init(bundleID: "com.google.Chrome",                 displayName: "Chrome",   kind: .browser),
        .init(bundleID: "com.apple.Safari",                  displayName: "Safari",   kind: .browser),
        .init(bundleID: "company.thebrowser.Browser",        displayName: "Arc",      kind: .browser),
        .init(bundleID: "com.microsoft.Edge",                displayName: "Edge",     kind: .browser),
        .init(bundleID: "org.mozilla.firefox",               displayName: "Firefox",  kind: .browser),
        .init(bundleID: "com.brave.Browser",                 displayName: "Brave",    kind: .browser),
        .init(bundleID: "net.imput.helium",                  displayName: "Helium",   kind: .browser),
        .init(bundleID: "im.helium.helium",                  displayName: "Helium",   kind: .browser),
    ]

    public static func appFor(bundleID: String) -> MeetingApp? {
        allowlist.first(where: { $0.bundleID == bundleID })
    }
}
