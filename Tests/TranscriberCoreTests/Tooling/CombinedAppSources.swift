import Foundation

/// Combined "logical sources" for source-guard tests.
///
/// Several app surfaces were split from single files into extension files
/// or folders (AppDelegate+<Area>.swift, Settings/, RecordingMenu/,
/// DesignSystem/). Source-guard tests still treat each surface as ONE
/// logical source: this helper concatenates the split files in the
/// original layout order, then appends any newly added files (sorted) so
/// new splits are never silently excluded from the guards. Each logical
/// source is built once per process and cached.
enum CombinedAppSources {
    /// Logical-source router keyed by the historical single-file names.
    /// Anything else reads the named file directly under
    /// `TranscriberApp/Scribe`.
    static func appSource(_ file: String) throws -> String {
        switch file {
        case "AppDelegate.swift": return try appDelegate()
        case "SettingsWindow.swift": return try settingsWindow()
        case "RecordingMenu.swift": return try recordingMenu()
        case "DesignSystem.swift": return try designSystem()
        default:
            return try String(
                contentsOfFile: scribeDir().appendingPathComponent(file).path, encoding: .utf8)
        }
    }

    /// AppDelegate.swift plus the AppDelegate+<Area>.swift extension files
    /// (glob-discovered, sorted), followed by the standalone helpers that
    /// were extracted from the original AppDelegate.swift. The standalone
    /// files are appended AFTER the AppDelegate files so position-sensitive
    /// assertions keep their anchors while the copy/privacy sweeps regain
    /// the coverage they had when AppDelegate.swift was a single file.
    static func appDelegate() throws -> String {
        try cache.value(for: "AppDelegate.swift") {
            let dir = scribeDir()
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            let extracted = [
                "ScreenRecordingRelaunchAssist.swift",
                "CompositeLocalModelDownloadStarter.swift",
                "AppearanceApplier.swift",
                "LaunchAtLoginController.swift",
                "StartStopHotKeyRegistrar.swift",
                "KeyboardShortcutSetting+App.swift",
            ]
            let parts = ["AppDelegate.swift"]
                + names.filter { $0.hasPrefix("AppDelegate+") && $0.hasSuffix(".swift") }.sorted()
                + extracted
            return try combine(parts: parts, in: dir)
        }
    }

    /// The Settings/ folder in the original SettingsWindow.swift layout
    /// order (declarations before their call sites), plus any other
    /// Settings/*.swift appended sorted.
    static func settingsWindow() throws -> String {
        try combinedFolder(
            named: "SettingsWindow.swift",
            folder: "Settings",
            layoutOrder: [
                "SettingsWindowController.swift", "SettingsFormModel.swift", "SettingsForm.swift",
                "FidelityChrome.swift", "ShortcutCapture.swift", "GeneralPanel.swift",
                "AudioPanel.swift", "ShortcutsPanel.swift", "VaultPanel.swift",
                "PrivacyPanel.swift", "PermissionsPanel.swift", "AboutPanel.swift",
                "FidelityComponents.swift", "PermissionsOnboardingWindow.swift",
                "InstalledAppSmokeSettingsFrame.swift",
            ]
        )
    }

    /// The RecordingMenu/ folder in the original RecordingMenu.swift layout
    /// order, plus any other RecordingMenu/*.swift appended sorted.
    static func recordingMenu() throws -> String {
        try combinedFolder(
            named: "RecordingMenu.swift",
            folder: "RecordingMenu",
            layoutOrder: [
                "RecordingMenu.swift", "RecordingMenuModel.swift",
                "RecordingPopoverContent.swift", "RecordingPopoverComponents.swift",
            ]
        )
    }

    /// The DesignSystem/ folder in the original DesignSystem.swift layout
    /// order, plus any other DesignSystem/*.swift appended sorted.
    static func designSystem() throws -> String {
        try combinedFolder(
            named: "DesignSystem.swift",
            folder: "DesignSystem",
            layoutOrder: [
                "DSTokens.swift", "DSButtonStyles.swift", "DSInteraction.swift",
                "WindowChrome.swift", "DSComponents.swift", "DebugVisualSnapshotWriter.swift",
            ]
        )
    }

    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tooling
            .deletingLastPathComponent()  // TranscriberCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    // MARK: - Internals

    private static func scribeDir() -> URL {
        repoRoot().appendingPathComponent("TranscriberApp/Scribe")
    }

    private static func combinedFolder(
        named cacheKey: String, folder: String, layoutOrder: [String]
    ) throws -> String {
        try cache.value(for: cacheKey) {
            let dir = scribeDir().appendingPathComponent(folder)
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            let parts = layoutOrder
                + names.filter { $0.hasSuffix(".swift") && !layoutOrder.contains($0) }.sorted()
            return try combine(parts: parts, in: dir)
        }
    }

    /// Reads every part with a throwing read: a missing or unreadable part
    /// file is a test-infrastructure error that must surface, not silently
    /// shrink the guarded source.
    private static func combine(parts: [String], in dir: URL) throws -> String {
        try parts.map { name in
            do {
                return try String(contentsOfFile: dir.appendingPathComponent(name).path, encoding: .utf8)
            } catch {
                throw CombinedAppSourcesError.unreadablePart(
                    "Cannot read \(dir.appendingPathComponent(name).path): \(error)")
            }
        }.joined(separator: "\n")
    }

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private var store: [String: String] = [:]
        private let lock = NSLock()

        func value(for key: String, compute: () throws -> String) throws -> String {
            lock.lock()
            defer { lock.unlock() }
            if let cached = store[key] { return cached }
            let value = try compute()
            store[key] = value
            return value
        }
    }
}

enum CombinedAppSourcesError: Error {
    case unreadablePart(String)
}
