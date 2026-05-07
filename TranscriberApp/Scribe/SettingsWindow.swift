import AppKit
import SwiftUI
import TranscriberCore
import UserNotifications

/// Phase η Settings window. Hosts a SwiftUI form bound to a snapshot of
/// `SessionSettings`; Save commits the snapshot back through
/// `SettingsStore.commit(_:)` (atomic multi-key write per Phase ζ P1.4).
@MainActor
final class SettingsWindowController {
    private let store: SettingsStore
    private let fallback: SettingsStore.Defaults
    private let keychainService: String
    private let keychainAccount: String
    private let onShowInMenuBarChange: @MainActor (Bool) -> Void
    private let onShortcutChange: @MainActor (KeyboardShortcutSetting) -> Void
    private let onAppearanceThemeChange: @MainActor (AppearanceTheme) -> Void
    private var window: NSWindow?

    init(
        store: SettingsStore,
        fallback: SettingsStore.Defaults,
        keychainService: String,
        keychainAccount: String,
        onShowInMenuBarChange: @escaping @MainActor (Bool) -> Void = { _ in },
        onShortcutChange: @escaping @MainActor (KeyboardShortcutSetting) -> Void = { _ in },
        onAppearanceThemeChange: @escaping @MainActor (AppearanceTheme) -> Void = { _ in }
    ) {
        self.store = store
        self.fallback = fallback
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.onShowInMenuBarChange = onShowInMenuBarChange
        self.onShortcutChange = onShortcutChange
        self.onAppearanceThemeChange = onAppearanceThemeChange
    }

    func show() {
        if let window = self.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let initial = SettingsSnapshotReader.read(fallback: fallback)
        let model = SettingsFormModel(
            initial: initial,
            keychainService: keychainService,
            keychainAccount: keychainAccount
        )

        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.title = "Scribe Settings"
        host.titleVisibility = .hidden
        host.titlebarAppearsTransparent = true
        host.minSize = NSSize(width: 880, height: 600)
        host.maxSize = NSSize(width: 880, height: 600)
        host.center()
        host.isOpaque = false
        host.backgroundColor = .clear
        host.isMovableByWindowBackground = true
        host.isReleasedWhenClosed = false
        // Codex PM-review UX-4: confidential UI.
        host.sharingType = WindowChromeSharing.confidential
        host.contentView = NSHostingView(rootView: SettingsForm(
            model: model,
            onAppearanceThemeChange: { [weak self] theme in
                AppearanceApplier.apply(theme)
                self?.onAppearanceThemeChange(theme)
                Task { await self?.store.setAppearanceTheme(theme) }
            },
            onLaunchAtLoginChange: { [weak self] enabled in
                do {
                    try LaunchAtLoginController.setEnabled(enabled)
                    Task { await self?.store.setLaunchAtLogin(enabled) }
                    model.saveError = nil
                } catch {
                    model.launchAtLogin = !enabled
                    model.saveError = "Failed to update launch at login: \(error.localizedDescription)"
                }
            },
            onShowInMenuBarChange: { [weak self] visible in
                self?.onShowInMenuBarChange(visible)
                Task { await self?.store.setShowInMenuBar(visible) }
                model.saveError = nil
            },
            onShortcutChange: { [weak self] shortcut in
                self?.onShortcutChange(shortcut)
                Task { await self?.store.setStartStopShortcut(shortcut) }
            },
            onSettingsChange: { [weak self] settings in
                do {
                    try await self?.store.commit(settings)
                } catch {
                    model.saveError = "Failed to save settings: \(error.localizedDescription)"
                }
            },
            onSave: { [weak self, weak host] settings in
                guard let self else { return }
                // Codex Phase η P1.1 + P1.2: actually await the commit
                // so encode failures surface to the user. Settings UI
                // stays open on error; closes only after success.
                do {
                    try await self.store.commit(settings)
                    host?.close()
                    self.window = nil
                } catch {
                    model.saveError = "Failed to save settings: \(error.localizedDescription)"
                }
            },
            onCancel: { [weak self, weak host] in
                host?.close()
                self?.window = nil
            }
        ))

        // Codex Phase η P1.3: a title-bar close should behave like
        // Cancel (drop the in-flight model + clear the window pointer
        // so the next open re-reads the on-disk snapshot fresh).
        let delegate = SettingsWindowDelegate { [weak self] in
            self?.window = nil
        }
        host.delegate = delegate
        objc_setAssociatedObject(host, &settingsWindowDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        WindowChrome.installGlass(on: host, material: .hudWindow)
        SettingsWindowChrome.makeCornersTransparent(on: host)

        self.window = host
        host.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }
}

/// Codex Phase η P1.3: NSWindowDelegate that fires when the title-bar
/// close button is hit. The closure resets the controller's window
/// pointer so a fresh `show()` re-loads the on-disk snapshot rather
/// than re-presenting the stale form.
private final class SettingsWindowDelegate: NSObject, NSWindowDelegate, @unchecked Sendable {
    private let onClose: @MainActor () -> Void
    init(onClose: @escaping @MainActor () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in onClose() }
    }
}

/// Associated-object key for retaining the SettingsWindowDelegate
/// alongside the host window without adding a stored property to
/// SettingsWindowController (which is constructed lazily).
nonisolated(unsafe) private var settingsWindowDelegateKey: UInt8 = 0

@MainActor
private enum SettingsWindowChrome {
    static let cornerRadius: CGFloat = 14

    static func makeCornersTransparent(on window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear

        guard let contentView = window.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.layer?.cornerRadius = cornerRadius
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.masksToBounds = true
    }
}

/// Observable backing store for the Settings form. SwiftUI binds to the
/// `@Published` fields; on Save the controller plucks `currentSettings`
/// out and hands it to `SettingsStore.commit(_:)`.
///
/// API key is stored in the macOS Keychain (separate from settings
/// blob); the form reads and writes it directly so the Save button
/// commits both at once.
@MainActor
final class SettingsFormModel: ObservableObject {
    @Published var outputRoot: URL
    @Published var engineMode: EngineMode
    @Published var keepRawStreams: Bool
    @Published var aecEnabled: Bool
    @Published var appearanceTheme: AppearanceTheme
    @Published var launchAtLogin: Bool
    @Published var showInMenuBar: Bool
    @Published var startStopShortcut: KeyboardShortcutSetting
    @Published var apiKey: String
    @Published var apiKeyEditedFromInitial: Bool = false
    @Published var saveError: String?

    let initialSnapshot: SessionSettings
    private let keychainService: String
    private let keychainAccount: String
    private let initialAPIKey: String

    init(
        initial: SessionSettings,
        keychainService: String,
        keychainAccount: String
    ) {
        self.initialSnapshot = initial
        self.outputRoot = initial.outputRoot
        self.engineMode = initial.engineMode
        self.keepRawStreams = initial.keepRawStreams
        self.aecEnabled = initial.aecEnabled
        self.appearanceTheme = initial.appearanceTheme
        self.launchAtLogin = LaunchAtLoginController.isEnabled
        self.showInMenuBar = initial.showInMenuBar
        self.startStopShortcut = initial.startStopShortcut
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount

        let keychain = KeychainStore(service: keychainService, account: keychainAccount)
        let stored = (try? keychain.read()) ?? ""
        self.initialAPIKey = stored
        self.apiKey = stored
    }

    var currentSettings: SessionSettings {
        SessionSettings(
            outputRoot: outputRoot,
            // Codex PM-review UX-10: pin to cloud while local is
            // disabled in UI. Local mode shipped only as protocol +
            // EngineSelector dispatch; saving it would create a
            // dead-end recording failure.
            engineMode: .cloud,
            keepRawStreams: keepRawStreams,
            aecEnabled: aecEnabled,
            // Privacy ack is one-way; if the user already acked it,
            // preserve. The Settings UI doesn't let them un-ack.
            privacyAcknowledged: initialSnapshot.privacyAcknowledged,
            appearanceTheme: appearanceTheme,
            launchAtLogin: launchAtLogin,
            showInMenuBar: showInMenuBar,
            startStopShortcut: startStopShortcut
        )
    }

    /// Commits the API key through Keychain. Returns true on success.
    func persistAPIKeyIfChanged() -> Bool {
        guard apiKey != initialAPIKey else { return true }
        let keychain = KeychainStore(service: keychainService, account: keychainAccount)
        do {
            if apiKey.isEmpty {
                try keychain.delete()
            } else {
                try keychain.write(apiKey)
            }
            saveError = nil
            return true
        } catch {
            self.saveError = "Failed to save API key: \(error.localizedDescription)"
            return false
        }
    }

    var outputRootIsInICloudDrive: Bool {
        let path = outputRoot.path
        return path.contains("/Library/Mobile Documents/")
    }

    var outputRootIsInSyncedStorage: Bool {
        let path = outputRoot.path
        // Third-party cloud providers; sync conflicts can corrupt
        // audio mid-write. iCloud Drive is broken out separately
        // because Apple's syncer handles it more gracefully and the
        // user typically wants their sessions backed up.
        let markers = [
            "/Library/CloudStorage/",
            "Dropbox",
            "Google Drive",
            "OneDrive",
            "Box"
        ]
        return markers.contains { path.contains($0) }
    }
}

private struct SettingsForm: View {
    @ObservedObject var model: SettingsFormModel
    let onAppearanceThemeChange: @MainActor (AppearanceTheme) -> Void
    let onLaunchAtLoginChange: @MainActor (Bool) -> Void
    let onShowInMenuBarChange: @MainActor (Bool) -> Void
    let onShortcutChange: @MainActor (KeyboardShortcutSetting) -> Void
    let onSettingsChange: @MainActor (SessionSettings) async -> Void
    let onSave: @MainActor (SessionSettings) async -> Void
    let onCancel: @MainActor () -> Void
    @State private var selectedPage: SettingsPage = .general

    var body: some View {
        HStack(spacing: 0) {
            FidelitySidebar(selection: $selectedPage, onClose: onCancel)
                .frame(width: FidelitySettings.sideWidth)
            FidelityDivider()
            VStack(spacing: 0) {
                FidelityHeader(title: selectedPage.title)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        if let saveError = model.saveError {
                            FidelityErrorBanner(message: saveError) {
                                model.saveError = nil
                            }
                        }
                        activePanel
                    }
                    .padding(.top, 28)
                    .padding(.horizontal, 36)
                    .padding(.bottom, 36)
                }
            }
            .frame(width: FidelitySettings.mainWidth)
        }
        .frame(width: FidelitySettings.windowWidth, height: FidelitySettings.windowHeight)
        .background(FidelityWindowSurface())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FidelitySettings.lineStrong, lineWidth: 1)
        )
        .preferredColorScheme(model.appearanceTheme.preferredColorScheme)
    }

    @ViewBuilder
    private var activePanel: some View {
        switch selectedPage {
        case .general:
            FidelityGeneralPanel(
                model: model,
                onAppearanceThemeChange: onAppearanceThemeChange,
                onLaunchAtLoginChange: onLaunchAtLoginChange,
                onShowInMenuBarChange: onShowInMenuBarChange,
                onShortcutChange: onShortcutChange,
                onSettingsChange: onSettingsChange
            )
        case .audio:
            FidelityAudioPanel(model: model, onSettingsChange: onSettingsChange)
        case .shortcuts:
            FidelityShortcutsPanel(
                model: model,
                onShortcutChange: onShortcutChange,
                onSettingsChange: onSettingsChange
            )
        case .vault:
            FidelityVaultPanel(model: model, onSettingsChange: onSettingsChange)
        case .privacy:
            FidelityPrivacyPanel(model: model)
        case .permissions:
            FidelityPermissionsPanel()
        case .about:
            FidelityAboutPanel()
        }
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case audio
    case shortcuts
    case vault
    case privacy
    case permissions
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .audio: return "Audio"
        case .shortcuts: return "Shortcuts"
        case .vault: return "Vault"
        case .privacy: return "Privacy"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "target"
        case .audio: return "waveform"
        case .shortcuts: return "keyboard"
        case .vault: return "cube"
        case .privacy: return "lock"
        case .permissions: return "checkmark.shield"
        case .about: return "info.circle"
        }
    }
}

private enum FidelitySettings {
    static let windowWidth: CGFloat = 880
    static let windowHeight: CGFloat = 600
    static let sideWidth: CGFloat = 200
    static let mainWidth: CGFloat = windowWidth - sideWidth - 1
    static let headerHeight: CGFloat = 38
    static let rowLabelWidth: CGFloat = 160
    static let rowGap: CGFloat = 18

    static let font = "Inter"
    static let rust = SwiftUI.Color(red: 0.93, green: 0.34, blue: 0.26)
    static let green = SwiftUI.Color(red: 0.35, green: 0.77, blue: 0.46)
    static let amber = SwiftUI.Color(red: 0.97, green: 0.72, blue: 0.24)
    static let ink = adaptive(
        dark: NSColor(calibratedWhite: 0.98, alpha: 1.0),
        light: NSColor(calibratedWhite: 0.08, alpha: 1.0)
    )
    static let ink2 = adaptive(
        dark: NSColor(calibratedWhite: 0.72, alpha: 1.0),
        light: NSColor(calibratedWhite: 0.28, alpha: 1.0)
    )
    static let ink3 = adaptive(
        dark: NSColor(calibratedWhite: 0.48, alpha: 1.0),
        light: NSColor(calibratedWhite: 0.42, alpha: 1.0)
    )
    static let line = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.06),
        light: NSColor(calibratedWhite: 0.0, alpha: 0.08)
    )
    static let lineRow = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.05),
        light: NSColor(calibratedWhite: 0.0, alpha: 0.07)
    )
    static let lineStrong = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.10),
        light: NSColor(calibratedWhite: 0.0, alpha: 0.12)
    )
    static let groupFill = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.025),
        light: NSColor(calibratedWhite: 1.0, alpha: 0.62)
    )
    static let iconFill = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.05),
        light: NSColor(calibratedWhite: 0.0, alpha: 0.055)
    )
    static let sidebarFill = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.025),
        light: NSColor(calibratedWhite: 0.0, alpha: 0.035)
    )
    static let selectedSidebarFill = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.06),
        light: NSColor(calibratedWhite: 0.0, alpha: 0.075)
    )
    static let controlShell = adaptive(
        dark: NSColor(calibratedWhite: 0.0, alpha: 0.30),
        light: NSColor(calibratedWhite: 0.88, alpha: 1.0)
    )
    static let controlStroke = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.08),
        light: NSColor(calibratedWhite: 0.0, alpha: 0.10)
    )
    static let controlSelected = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.10),
        light: NSColor(calibratedWhite: 1.0, alpha: 0.82)
    )
    static let controlSelectedStroke = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.08),
        light: NSColor(calibratedRed: 0.02, green: 0.39, blue: 0.78, alpha: 1.0)
    )
    static let fieldFill = adaptive(
        dark: NSColor(calibratedWhite: 0.0, alpha: 0.24),
        light: NSColor(calibratedWhite: 1.0, alpha: 0.76)
    )
    static let pathFieldFill = adaptive(
        dark: NSColor(calibratedWhite: 0.0, alpha: 0.30),
        light: NSColor(calibratedWhite: 1.0, alpha: 0.76)
    )
    static let meterFill = adaptive(
        dark: NSColor(calibratedWhite: 0.0, alpha: 0.35),
        light: NSColor(calibratedWhite: 0.0, alpha: 0.10)
    )
    static let codeFill = adaptive(
        dark: NSColor(calibratedWhite: 0.0, alpha: 0.34),
        light: NSColor(calibratedWhite: 1.0, alpha: 0.68)
    )
    static let offToggleFill = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.10),
        light: NSColor(calibratedWhite: 0.0, alpha: 0.10)
    )
    static let keyFill = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.06),
        light: NSColor(calibratedWhite: 1.0, alpha: 0.88)
    )
    static let keyStroke = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.10),
        light: NSColor(calibratedWhite: 0.0, alpha: 0.12)
    )
    static let ghostButtonFill = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.0),
        light: NSColor(calibratedWhite: 1.0, alpha: 0.50)
    )
    static let ghostButtonStroke = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.0),
        light: NSColor(calibratedWhite: 0.0, alpha: 0.08)
    )
    static let secondaryButtonFill = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.04),
        light: NSColor(calibratedWhite: 1.0, alpha: 0.70)
    )
    static let secondaryButtonStroke = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.10),
        light: NSColor(calibratedWhite: 0.0, alpha: 0.10)
    )
    static let accentFocus = SwiftUI.Color(red: 0.02, green: 0.39, blue: 0.78)

    static let headerFont = SwiftUI.Font.custom(font, size: 13).weight(.semibold)
    static let titleFont = SwiftUI.Font.custom(font, size: 22).weight(.semibold)
    static let subtitleFont = SwiftUI.Font.custom(font, size: 13).weight(.regular)
    static let sectionFont = SwiftUI.Font.custom(font, size: 11).weight(.semibold)
    static let rowFont = SwiftUI.Font.custom(font, size: 13).weight(.regular)
    static let rowValueFont = SwiftUI.Font.custom(font, size: 13).weight(.regular)
    static let controlFont = SwiftUI.Font.custom(font, size: 12.5).weight(.medium)
    static let keyFont = SwiftUI.Font.custom(font, size: 12).weight(.medium)

    private static func adaptive(dark: NSColor, light: NSColor) -> SwiftUI.Color {
        SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? light : dark
        })
    }
}

private struct FidelityWindowSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            base
            topRightGlow
            topLeftGlow
            bottomVignette
        }
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [.clear, topHairline, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
            .padding(.horizontal, 24)
        }
    }

    private var isLight: Bool { colorScheme == .light }

    private var base: SwiftUI.Color {
        isLight ? SwiftUI.Color(red: 0.96, green: 0.97, blue: 0.98) : SwiftUI.Color(red: 0.028, green: 0.004, blue: 0.010)
    }

    private var topRightGlow: RadialGradient {
        RadialGradient(
            colors: [
                isLight ? SwiftUI.Color(red: 0.86, green: 0.92, blue: 0.98).opacity(0.94) : SwiftUI.Color(red: 0.30, green: 0.05, blue: 0.10).opacity(0.78),
                SwiftUI.Color.clear
            ],
            center: UnitPoint(x: 0.75, y: 0.06),
            startRadius: 0,
            endRadius: 520
        )
    }

    private var topLeftGlow: RadialGradient {
        RadialGradient(
            colors: [
                isLight ? SwiftUI.Color(red: 1.0, green: 0.88, blue: 0.84).opacity(0.70) : SwiftUI.Color(red: 0.36, green: 0.11, blue: 0.07).opacity(0.58),
                SwiftUI.Color.clear
            ],
            center: UnitPoint(x: 0.03, y: 0.01),
            startRadius: 0,
            endRadius: 480
        )
    }

    private var bottomVignette: RadialGradient {
        RadialGradient(
            colors: [
                isLight ? SwiftUI.Color.white.opacity(0.42) : SwiftUI.Color.black.opacity(0.82),
                SwiftUI.Color.clear
            ],
            center: UnitPoint(x: 0.50, y: 1.02),
            startRadius: 90,
            endRadius: 500
        )
    }

    private var topHairline: SwiftUI.Color {
        isLight ? SwiftUI.Color.white.opacity(0.60) : SwiftUI.Color.white.opacity(0.20)
    }
}

private struct FidelityDivider: View {
    var body: some View {
        Rectangle()
            .fill(FidelitySettings.line)
            .frame(width: 1)
    }
}

private struct FidelityHeader: View {
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(FidelitySettings.headerFont)
                    .foregroundStyle(FidelitySettings.ink)
                    .tracking(-0.13)
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: FidelitySettings.headerHeight)
            Rectangle()
                .fill(FidelitySettings.line)
                .frame(height: 1)
        }
    }
}

private struct FidelitySidebar: View {
    @Binding var selection: SettingsPage
    let onClose: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                FidelityTrafficButton(color: SwiftUI.Color(red: 1.0, green: 0.31, blue: 0.29)) {
                    onClose()
                }
                FidelityTrafficButton(color: SwiftUI.Color(red: 1.0, green: 0.75, blue: 0.13)) {
                    NSApp.keyWindow?.miniaturize(nil)
                }
                FidelityTrafficButton(color: SwiftUI.Color(red: 0.19, green: 0.80, blue: 0.30)) {
                    NSApp.keyWindow?.zoom(nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: FidelitySettings.headerHeight)
            .padding(.leading, 15)

            VStack(spacing: 1) {
                ForEach(SettingsPage.allCases) { page in
                    FidelitySidebarItem(
                        symbol: page.symbol,
                        title: page.title,
                        selected: selection == page
                    ) {
                        selection = page
                    }
                }
            }
            .padding(8)
            Spacer(minLength: 0)
        }
        .background(FidelitySettings.sidebarFill)
    }
}

private struct FidelityTrafficButton: View {
    let color: SwiftUI.Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .stroke(SwiftUI.Color.black.opacity(0.22), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct FidelitySidebarItem: View {
    let symbol: String
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? FidelitySettings.rust : FidelitySettings.iconFill)
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? SwiftUI.Color.white : FidelitySettings.ink3)
                }
                .frame(width: 22, height: 22)
                Text(title)
                    .font(FidelitySettings.rowFont)
                    .foregroundStyle(selected ? FidelitySettings.ink : FidelitySettings.ink2)
                    .tracking(-0.13)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? FidelitySettings.selectedSidebarFill : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

@MainActor
private enum ShortcutCapturePanel {
    static func present(
        current: KeyboardShortcutSetting,
        onCapture: @escaping @MainActor (KeyboardShortcutSetting) -> Void
    ) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Change Shortcut"
        panel.isReleasedWhenClosed = false
        panel.sharingType = WindowChromeSharing.confidential

        let view = ShortcutCaptureView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 360, height: 150))
        view.current = current
        view.onCancel = { panel.close() }
        view.onCapture = { shortcut in
            onCapture(shortcut)
            panel.close()
        }
        panel.contentView = view
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(view)
    }
}

@MainActor
private final class ShortcutCaptureView: NSView {
    var current: KeyboardShortcutSetting = .defaultStartStop {
        didSet { currentLabel.stringValue = "Current: \(current.displayString)" }
    }
    var onCapture: (@MainActor (KeyboardShortcutSetting) -> Void)?
    var onCancel: (@MainActor () -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Press the new start / stop shortcut")
    private let currentLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "Use Command, Shift, Option, or Control with a letter or number. Esc cancels.")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        [titleLabel, currentLabel, hintLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.alignment = .center
            addSubview($0)
        }
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        currentLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        currentLabel.stringValue = "Current: \(current.displayString)"

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            currentLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            currentLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            currentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            hintLabel.topAnchor.constraint(equalTo: currentLabel.bottomAnchor, constant: 18),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        guard let key = event.charactersIgnoringModifiers?.uppercased(), key.count == 1 else {
            NSSound.beep()
            return
        }
        let modifiers = event.shortcutModifiers
        guard !modifiers.isEmpty else {
            NSSound.beep()
            return
        }
        onCapture?(KeyboardShortcutSetting(key: key, keyCode: event.keyCode, modifiers: modifiers))
    }
}

private extension NSEvent {
    var shortcutModifiers: [ShortcutModifier] {
        var result: [ShortcutModifier] = []
        if modifierFlags.contains(.command) { result.append(.command) }
        if modifierFlags.contains(.shift) { result.append(.shift) }
        if modifierFlags.contains(.option) { result.append(.option) }
        if modifierFlags.contains(.control) { result.append(.control) }
        return result
    }
}

private struct FidelityGeneralPanel: View {
    @ObservedObject var model: SettingsFormModel
    let onAppearanceThemeChange: @MainActor (AppearanceTheme) -> Void
    let onLaunchAtLoginChange: @MainActor (Bool) -> Void
    let onShowInMenuBarChange: @MainActor (Bool) -> Void
    let onShortcutChange: @MainActor (KeyboardShortcutSetting) -> Void
    let onSettingsChange: @MainActor (SessionSettings) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("General")
                .font(FidelitySettings.titleFont)
                .foregroundStyle(FidelitySettings.ink)
                .tracking(-0.55)
                .padding(.bottom, 6)
            Text("Scribe records and transcribes locally on your Mac. Nothing leaves the device.")
                .font(FidelitySettings.subtitleFont)
                .foregroundStyle(FidelitySettings.ink2)
                .lineSpacing(4)
                .tracking(-0.08)
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.bottom, 24)

            FidelitySection(title: "Appearance") {
                FidelityRow(label: "Theme") {
                    FidelitySegmentedControl(selection: Binding(
                        get: { model.appearanceTheme },
                        set: { theme in
                            guard model.appearanceTheme != theme else { return }
                            model.appearanceTheme = theme
                            onAppearanceThemeChange(theme)
                            persistSettings()
                        }
                    ))
                }
            }
            .padding(.bottom, 22)

            FidelitySection(title: "Shortcut") {
                FidelityRow(label: "Start / stop recording") {
                    HStack(spacing: 8) {
                        HStack(spacing: 3) {
                            ForEach(Array(model.startStopShortcut.displayString.map(String.init).enumerated()), id: \.offset) { _, part in
                                FidelityKey(part)
                            }
                        }
                        FidelityGhostButton("Change…") {
                            ShortcutCapturePanel.present(current: model.startStopShortcut) { shortcut in
                                model.startStopShortcut = shortcut
                                onShortcutChange(shortcut)
                                persistSettings()
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 22)

            FidelitySection(title: "App") {
                FidelityRow(label: "Launch at login") {
                    FidelityToggle(isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { enabled in
                            model.launchAtLogin = enabled
                            onLaunchAtLoginChange(enabled)
                        }
                    ))
                }
                FidelityRowDivider()
                FidelityRow(label: "Show in menu bar") {
                    FidelityToggle(isOn: Binding(
                        get: { model.showInMenuBar },
                        set: { visible in
                            model.showInMenuBar = visible
                            onShowInMenuBarChange(visible)
                        }
                    ))
                }
            }
        }
    }

    private func persistSettings() {
        Task { await onSettingsChange(model.currentSettings) }
    }
}

private struct FidelityAudioPanel: View {
    @ObservedObject var model: SettingsFormModel
    let onSettingsChange: @MainActor (SessionSettings) async -> Void
    @State private var inputDevice = "MacBook Pro Microphone"
    @State private var language = "English (auto-detect dialect)"
    @State private var speakerLabels = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FidelityPanelIntro(
                title: "Audio",
                subtitle: "Configure how Scribe captures and transcribes voice."
            )

            FidelitySection(title: "Recording") {
                FidelityRow(label: "Input device") {
                    HStack(spacing: 12) {
                        FidelitySelectLike(
                            selection: $inputDevice,
                            options: ["MacBook Pro Microphone", "AirPods Pro", "External USB-C Mic", "System default"],
                            minWidth: 240
                        )
                        FidelityMeter()
                    }
                }
                FidelityRowDivider()
                FidelityRow(label: "Language") {
                    FidelitySelectLike(
                        selection: $language,
                        options: ["English (auto-detect dialect)", "English — US", "English — UK", "Spanish", "French", "German", "Japanese"],
                        minWidth: 240
                    )
                }
                FidelityRowDivider()
                FidelityRow(label: "Speaker labels") {
                    HStack(spacing: 10) {
                        FidelityToggle(isOn: $speakerLabels)
                        FidelityHelpText("Diarize speakers when more than one voice is detected.")
                    }
                }
            }
        }
    }

    private func persistSettings() {
        Task { await onSettingsChange(model.currentSettings) }
    }
}

private struct FidelityShortcutsPanel: View {
    @ObservedObject var model: SettingsFormModel
    let onShortcutChange: @MainActor (KeyboardShortcutSetting) -> Void
    let onSettingsChange: @MainActor (SessionSettings) async -> Void
    @State private var menuShortcut = KeyboardShortcutSetting(key: "S", keyCode: 1, modifiers: [.control, .command])
    @State private var clipboardShortcut: KeyboardShortcutSetting?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FidelityPanelIntro(
                title: "Shortcuts",
                subtitle: "Keyboard shortcuts for quick capture."
            )

            FidelitySection(title: "Global") {
                FidelityRow(label: "Start / stop recording") {
                    HStack(spacing: 8) {
                        FidelityKeyboardShortcutDisplay(shortcut: model.startStopShortcut)
                        FidelityGhostButton("Change…") {
                            ShortcutCapturePanel.present(current: model.startStopShortcut) { shortcut in
                                model.startStopShortcut = shortcut
                                onShortcutChange(shortcut)
                                Task { await onSettingsChange(model.currentSettings) }
                            }
                        }
                    }
                }
                FidelityRowDivider()
                FidelityRow(label: "Open menu bar popover") {
                    HStack(spacing: 8) {
                        FidelityKeyboardShortcutDisplay(shortcut: menuShortcut)
                        FidelityGhostButton("Change…") {
                            ShortcutCapturePanel.present(current: menuShortcut) { shortcut in
                                menuShortcut = shortcut
                            }
                        }
                    }
                }
                FidelityRowDivider()
                FidelityRow(label: "New transcript from clipboard") {
                    HStack(spacing: 8) {
                        if let clipboardShortcut {
                            FidelityKeyboardShortcutDisplay(shortcut: clipboardShortcut)
                        } else {
                            FidelityHelpText("Not set")
                        }
                        FidelityGhostButton(clipboardShortcut == nil ? "Set…" : "Change…") {
                            ShortcutCapturePanel.present(current: clipboardShortcut ?? model.startStopShortcut) { shortcut in
                                clipboardShortcut = shortcut
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct FidelityVaultPanel: View {
    @ObservedObject var model: SettingsFormModel
    let onSettingsChange: @MainActor (SessionSettings) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FidelityPanelIntro(
                title: "Vault",
                subtitle: "Where your transcripts and audio live on disk."
            )

            FidelitySection(title: "Location") {
                FidelityRow(label: "Save transcripts to") {
                    HStack(spacing: 8) {
                        FidelityPathField(path: shortenedPath)
                            .frame(maxWidth: .infinity)
                        FidelitySecondaryButton("Choose…") { pickFolder() }
                        FidelityGhostButton("Reveal") { revealFolder(model.outputRoot) }
                    }
                }
                FidelityRowDivider()
                FidelityRow(label: "On disk") {
                    FidelityStorageStat(url: model.outputRoot)
                }
            }
        }
    }

    private var shortenedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return model.outputRoot.path.replacingOccurrences(of: home, with: "~")
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.outputRoot
        if panel.runModal() == .OK, let url = panel.url {
            model.outputRoot = url
            Task { await onSettingsChange(model.currentSettings) }
        }
    }

    private func revealFolder(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
            model.saveError = nil
        } catch {
            model.saveError = "Failed to open folder: \(error.localizedDescription)"
        }
    }
}

private struct FidelityPrivacyPanel: View {
    @ObservedObject var model: SettingsFormModel
    @State private var hideFromScreenRecordings = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FidelityPanelIntro(
                title: "Privacy",
                subtitle: "Everything stays on your Mac. These options give you a little extra control."
            )

            FidelitySection(title: "Visibility") {
                FidelityRow(label: "Hide from screen recordings") {
                    HStack(spacing: 10) {
                        FidelityToggle(isOn: $hideFromScreenRecordings)
                        FidelityHelpText("Scribe windows won’t appear in screenshots, screen recordings, or shared screens.")
                    }
                }
            }
        }
    }
}

private struct FidelityPermissionsPanel: View {
    @State private var microphoneStatus: PermissionStatus = .notDetermined
    @State private var screenRecordingStatus: PermissionStatus = .notDetermined
    @State private var calendarStatus: PermissionStatus = .notDetermined
    @State private var notificationStatus: PermissionStatus = .notDetermined

    private let permissions = PermissionsService()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FidelityPanelIntro(
                title: "Permissions",
                subtitle: "Scribe needs a few macOS permissions to capture meetings. Granted permissions stay in System Settings; revoke any of them at any time."
            )

            FidelitySection(title: "Required") {
                FidelityPermissionRow(
                    title: "Microphone",
                    status: microphoneStatus,
                    help: "Captures your voice from the mic.",
                    action: .systemSettings {
                        openSystemSettings("Privacy_Microphone")
                    }
                )
                FidelityRowDivider()
                FidelityPermissionRow(
                    title: "Screen Recording",
                    status: screenRecordingStatus,
                    help: "Captures system audio so other speakers are transcribed. No video is recorded.",
                    action: .systemSettings {
                        openSystemSettings("Privacy_ScreenCapture")
                    }
                )
            }
            .padding(.bottom, 22)

            FidelitySection(title: "Optional") {
                FidelityPermissionRow(
                    title: "Calendar",
                    status: calendarStatus,
                    help: "Names transcripts using the meeting title and labels speakers with attendee names.",
                    action: .systemSettings {
                        openSystemSettings("Privacy_Calendars")
                    }
                )
                FidelityRowDivider()
                FidelityPermissionRow(
                    title: "Notifications",
                    status: notificationStatus,
                    help: "Tells you when a transcript is ready or when a meeting is detected.",
                    action: .secondary("Allow…") {
                        Task { await requestNotifications() }
                    }
                )
            }
        }
        .task { await refreshStatuses() }
    }

    private func openSystemSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    private func refreshStatuses() async {
        let probe = DefaultPermissionStatusProbe(permissions: permissions)
        async let microphone = probe.microphone()
        async let screen = probe.screenRecording()
        async let calendar = probe.calendar()
        async let notifications = notificationPermissionStatus()
        microphoneStatus = await microphone
        screenRecordingStatus = await screen
        calendarStatus = await calendar
        notificationStatus = await notifications
    }

    @MainActor
    private func requestNotifications() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            notificationStatus = granted ? .granted : .denied
        } catch {
            notificationStatus = .denied
        }
    }

    private func notificationPermissionStatus() async -> PermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .granted
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }
}

private struct FidelityAboutPanel: View {
    @State private var microphoneStatus: PermissionStatus = .notDetermined

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FidelityPanelIntro(
                title: "About",
                subtitle: "Scribe — every call, captured locally."
            )

            FidelitySection(title: "App") {
                FidelityRow(label: "Version") {
                    HStack(spacing: 8) {
                        Text(BuildInfo.version)
                            .font(FidelitySettings.rowValueFont)
                            .foregroundStyle(FidelitySettings.ink)
                        FidelityGhostButton("Check for updates") {
                            if let url = URL(string: "https://github.com/Newarr/scribe/releases") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                FidelityRowDivider()
                FidelityRow(label: "Build") {
                    Text("2026.05.07 · macOS 14.4+")
                        .font(FidelitySettings.rowValueFont)
                        .foregroundStyle(FidelitySettings.ink2)
                }
                FidelityRowDivider()
                FidelityRow(label: "Mic access") {
                    Text(microphoneStatus.fidelityLabel)
                        .font(FidelitySettings.rowValueFont.weight(.medium))
                        .foregroundStyle(microphoneStatus.fidelityColor)
                }
            }
        }
        .task {
            microphoneStatus = PermissionsService().microphoneStatus()
        }
    }
}

private struct FidelityPanelIntro: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(FidelitySettings.titleFont)
                .foregroundStyle(FidelitySettings.ink)
                .tracking(-0.55)
                .padding(.bottom, 6)
            Text(subtitle)
                .font(FidelitySettings.subtitleFont)
                .foregroundStyle(FidelitySettings.ink2)
                .lineSpacing(4)
                .tracking(-0.08)
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.bottom, 24)
        }
    }
}

private struct FidelityErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FidelitySettings.rust)
            Text(message)
                .font(FidelitySettings.rowValueFont)
                .foregroundStyle(FidelitySettings.ink2)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FidelitySettings.ink3)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(FidelitySettings.rust.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FidelitySettings.rust.opacity(0.22), lineWidth: 1)
        )
    }
}

private struct FidelityStatusDot: View {
    let color: SwiftUI.Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }
}

private struct FidelitySelectLike: View {
    @Binding var selection: String
    let options: [String]
    let minWidth: CGFloat

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(option) {
                    selection = option
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selection)
                    .font(FidelitySettings.controlFont)
                    .foregroundStyle(FidelitySettings.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(FidelitySettings.ink3)
            }
            .padding(.horizontal, 11)
            .frame(minWidth: minWidth, minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(FidelitySettings.fieldFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(FidelitySettings.line, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct FidelityMeter: View {
    @State private var high = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(FidelitySettings.meterFill)
                    .overlay(Capsule().stroke(FidelitySettings.line, lineWidth: 1))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [FidelitySettings.green, FidelitySettings.green, FidelitySettings.amber, FidelitySettings.rust],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * (high ? 0.72 : 0.38))
            }
        }
        .frame(width: 200, height: 6)
        .clipShape(Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                high = true
            }
        }
    }
}

private struct FidelityHelpText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(SwiftUI.Font.custom(FidelitySettings.font, size: 11.5))
            .foregroundStyle(FidelitySettings.ink3)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct FidelityKeyboardShortcutDisplay: View {
    let shortcut: KeyboardShortcutSetting

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(shortcut.displayString.map(String.init).enumerated()), id: \.offset) { _, part in
                FidelityKey(part)
            }
        }
    }
}

private struct FidelityPathField: View {
    let path: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FidelitySettings.ink3)
            Text(attributedPath)
                .font(FidelitySettings.controlFont)
                .foregroundStyle(FidelitySettings.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(FidelitySettings.pathFieldFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(FidelitySettings.line, lineWidth: 1)
        )
    }

    private var attributedPath: AttributedString {
        var value = AttributedString(path)
        if let range = value.range(of: "Scribe") {
            value[range].foregroundColor = FidelitySettings.ink
            value[range].font = FidelitySettings.controlFont.weight(.medium)
        }
        return value
    }
}

private struct FidelityStorageStat: View {
    let url: URL

    var body: some View {
        let stat = storageStat
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(stat.transcriptCount)")
                .font(SwiftUI.Font.custom(FidelitySettings.font, size: 15).weight(.semibold))
                .foregroundStyle(FidelitySettings.ink)
                .monospacedDigit()
            Text("transcripts")
                .font(FidelitySettings.rowValueFont)
                .foregroundStyle(FidelitySettings.ink2)
            Text("·")
                .font(FidelitySettings.rowValueFont)
                .foregroundStyle(FidelitySettings.ink3)
            Text(stat.byteCount)
                .font(SwiftUI.Font.custom(FidelitySettings.font, size: 15).weight(.semibold))
                .foregroundStyle(FidelitySettings.ink)
                .monospacedDigit()
        }
    }

    private var storageStat: (transcriptCount: Int, byteCount: String) {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, "0 KB")
        }

        var count = 0
        var bytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            if fileURL.pathExtension.lowercased() == "md" {
                count += 1
            }
            bytes += Int64(values?.fileSize ?? 0)
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = bytes < 1_000_000 ? [.useKB] : [.useMB, .useGB]
        return (count, formatter.string(fromByteCount: bytes))
    }
}

private enum FidelityPermissionAction {
    case systemSettings(@MainActor () -> Void)
    case secondary(String, @MainActor () -> Void)

    var title: String {
        switch self {
        case .systemSettings:
            return "Open in System Settings"
        case .secondary(let title, _):
            return title
        }
    }

    var isSystemSettings: Bool {
        if case .systemSettings = self { return true }
        return false
    }

    @MainActor
    func callAsFunction() {
        switch self {
        case .systemSettings(let action), .secondary(_, let action):
            action()
        }
    }
}

private struct FidelityPermissionRow: View {
    let title: String
    let status: PermissionStatus
    let help: String
    let action: FidelityPermissionAction

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(status.fidelityColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(FidelitySettings.rowFont.weight(.medium))
                        .foregroundStyle(FidelitySettings.ink)
                    Text(status.fidelityLabel)
                        .font(SwiftUI.Font.custom(FidelitySettings.font, size: 11.5).weight(.medium))
                        .foregroundStyle(status.fidelityColor)
                }
                Text(help)
                    .font(SwiftUI.Font.custom(FidelitySettings.font, size: 11.5))
                    .foregroundStyle(FidelitySettings.ink3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            FidelityPermissionButton(action: action)
                .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

private struct FidelityPermissionButton: View {
    let action: FidelityPermissionAction

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 4) {
                Text(action.title)
                    .font(FidelitySettings.controlFont)
                if action.isSystemSettings {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 10.5, weight: .medium))
                        .opacity(0.58)
                }
            }
            .foregroundStyle(action.isSystemSettings ? FidelitySettings.ink2 : FidelitySettings.ink)
            .padding(.horizontal, action.isSystemSettings ? 6 : 11)
            .frame(height: 28)
            .background(buttonBackground)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private var buttonBackground: some View {
        if action.isSystemSettings {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(SwiftUI.Color.clear)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(FidelitySettings.secondaryButtonFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(FidelitySettings.secondaryButtonStroke, lineWidth: 1)
                )
        }
    }
}

private extension PermissionStatus {
    var fidelityLabel: String {
        switch self {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not asked"
        }
    }

    var fidelityColor: SwiftUI.Color {
        switch self {
        case .granted: return FidelitySettings.green
        case .denied: return FidelitySettings.amber
        case .notDetermined: return FidelitySettings.ink3
        }
    }
}

private struct FidelityCodeBlock<Actions: View>: View {
    let text: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(FidelitySettings.keyFont)
                .foregroundStyle(SwiftUI.Color(red: 1.0, green: 0.55, blue: 0.46))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions()
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(FidelitySettings.codeFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(FidelitySettings.line, lineWidth: 1)
        )
    }
}

private struct FidelitySection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(FidelitySettings.sectionFont)
                .foregroundStyle(FidelitySettings.ink3)
                .tracking(0.66)
                .padding(.leading, 14)
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(FidelitySettings.groupFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(FidelitySettings.line, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct FidelityRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: FidelitySettings.rowGap) {
            Text(label)
                .font(FidelitySettings.rowFont)
                .foregroundStyle(FidelitySettings.ink2)
                .tracking(-0.13)
                .frame(width: FidelitySettings.rowLabelWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
    }
}

private struct FidelityRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(FidelitySettings.lineRow)
            .frame(height: 1)
    }
}

private struct FidelitySegmentedControl: View {
    @Binding var selection: AppearanceTheme

    private let segments: [(AppearanceTheme, String, String)] = [
        (.system, "System", "display"),
        (.light, "Light", "sun.max"),
        (.dark, "Dark", "moon")
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments, id: \.0) { segment in
                FidelitySegment(
                    title: segment.1,
                    symbol: segment.2,
                    selected: selection == segment.0
                ) {
                    selection = segment.0
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(FidelitySettings.controlShell)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(FidelitySettings.controlStroke, lineWidth: 1)
        )
    }
}

private struct FidelitySegment: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(FidelitySettings.controlFont)
            }
            .foregroundStyle(selected ? FidelitySettings.ink : FidelitySettings.ink2)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .frame(minWidth: 72)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selected ? FidelitySettings.controlSelected : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(selected ? FidelitySettings.controlSelectedStroke : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct FidelityKey: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(FidelitySettings.keyFont)
            .foregroundStyle(FidelitySettings.ink)
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, text.count > 1 ? 6 : 0)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(FidelitySettings.keyFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(FidelitySettings.keyStroke, lineWidth: 1)
            )
    }
}

private struct FidelityGhostButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void = {}) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(FidelitySettings.controlFont)
                .foregroundStyle(FidelitySettings.ink2)
                .frame(height: 28)
                .padding(.horizontal, 11)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(FidelitySettings.ghostButtonFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(FidelitySettings.ghostButtonStroke, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct FidelitySecondaryButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void = {}) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(FidelitySettings.controlFont)
                .foregroundStyle(FidelitySettings.ink)
                .frame(height: 28)
                .padding(.horizontal, 11)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(FidelitySettings.secondaryButtonFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(FidelitySettings.secondaryButtonStroke, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct FidelityToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(isOn ? FidelitySettings.rust : FidelitySettings.offToggleFill)
                    .overlay(
                        Capsule()
                            .stroke(isOn ? FidelitySettings.rust : FidelitySettings.line, lineWidth: 1)
                    )
                Circle()
                    .fill(SwiftUI.Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: SwiftUI.Color.black.opacity(0.25), radius: 1, x: 0, y: 1)
                    .offset(x: isOn ? 13 : 1)
            }
            .frame(width: 30, height: 18)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
    }
}
