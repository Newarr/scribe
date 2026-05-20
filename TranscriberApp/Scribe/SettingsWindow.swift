import AppKit
import CoreGraphics
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
    private let engineReadiness: EngineReadinessProbing
    private let onRetryLocalModel: @MainActor () async -> LocalModelCacheStatus
    private let onClearLocalModelCache: @MainActor () async throws -> Void
    private let onShowInMenuBarChange: @MainActor (Bool) -> Void
    private let onShortcutChange: @MainActor (KeyboardShortcutSetting) -> Void
    private let onAppearanceThemeChange: @MainActor (AppearanceTheme) -> Void
    private var window: NSWindow?

    init(
        store: SettingsStore,
        fallback: SettingsStore.Defaults,
        keychainService: String,
        keychainAccount: String,
        engineReadiness: EngineReadinessProbing,
        onRetryLocalModel: @escaping @MainActor () async -> LocalModelCacheStatus = { .notDownloaded(modelID: CohereMLXBackend.modelID) },
        onClearLocalModelCache: @escaping @MainActor () async throws -> Void = {},
        onShowInMenuBarChange: @escaping @MainActor (Bool) -> Void = { _ in },
        onShortcutChange: @escaping @MainActor (KeyboardShortcutSetting) -> Void = { _ in },
        onAppearanceThemeChange: @escaping @MainActor (AppearanceTheme) -> Void = { _ in }
    ) {
        self.store = store
        self.fallback = fallback
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.engineReadiness = engineReadiness
        self.onRetryLocalModel = onRetryLocalModel
        self.onClearLocalModelCache = onClearLocalModelCache
        self.onShowInMenuBarChange = onShowInMenuBarChange
        self.onShortcutChange = onShortcutChange
        self.onAppearanceThemeChange = onAppearanceThemeChange
    }

    func show(focus: EngineSettingsCardFocus? = nil) {
        if let window = self.window {
            if let focus {
                NotificationCenter.default.post(name: .settingsEngineFocusRequested, object: focus.rawValue)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let initial = SettingsSnapshotReader.read(fallback: fallback)
        let model = SettingsFormModel(
            initial: initial,
            keychainService: keychainService,
            keychainAccount: keychainAccount,
            engineReadiness: engineReadiness,
            onRetryLocalModel: onRetryLocalModel,
            onClearLocalModelCache: onClearLocalModelCache
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
                // Keychain persistence must complete before settings commit,
                // readiness refresh, or closing. If Keychain fails, the
                // window stays open with a non-secret error and Cloud
                // readiness is not marked ready from the typed value.
                guard await model.persistAPIKeyIfChanged() else { return }
                do {
                    try await self.store.commit(settings)
                    await model.refreshEngineViewState()
                    host?.close()
                    self.window = nil
                } catch {
                    model.saveError = "Failed to save settings: \(error.localizedDescription)"
                }
            },
            onCancel: { [weak self, weak host] in
                guard model.canCloseOrSurfaceUnsavedCloudKeyWarning() else { return }
                host?.close()
                self?.window = nil
            },
            initialEngineFocus: focus
        ))

        // Codex Phase η P1.3: a title-bar close should behave like
        // Cancel (drop the in-flight model + clear the window pointer
        // so the next open re-reads the on-disk snapshot fresh).
        let delegate = SettingsWindowDelegate(
            shouldClose: {
                model.canCloseOrSurfaceUnsavedCloudKeyWarning()
            },
            onClose: { [weak self] in
                self?.window = nil
            }
        )
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
    private let shouldClose: @MainActor () -> Bool
    private let onClose: @MainActor () -> Void

    init(
        shouldClose: @escaping @MainActor () -> Bool = { true },
        onClose: @escaping @MainActor () -> Void
    ) {
        self.shouldClose = shouldClose
        self.onClose = onClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldClose()
    }

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
    @Published var isSavingCloudAPIKey: Bool = false
    @Published var saveError: String?
    @Published var engineViewState: EngineSettingsViewState
    @Published var pendingLocalModelRemoval: EngineSettingsEffect?

    let initialSnapshot: SessionSettings
    private let keychainService: String
    private let keychainAccount: String
    private var initialAPIKey: String
    private let engineReadiness: EngineReadinessProbing
    private let onRetryLocalModel: @MainActor () async -> LocalModelCacheStatus
    private let onClearLocalModelCache: @MainActor () async throws -> Void

    init(
        initial: SessionSettings,
        keychainService: String,
        keychainAccount: String,
        engineReadiness: EngineReadinessProbing,
        onRetryLocalModel: @escaping @MainActor () async -> LocalModelCacheStatus = { .notDownloaded(modelID: CohereMLXBackend.modelID) },
        onClearLocalModelCache: @escaping @MainActor () async throws -> Void = {}
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
        self.engineReadiness = engineReadiness
        self.onRetryLocalModel = onRetryLocalModel
        self.onClearLocalModelCache = onClearLocalModelCache

        let keychain = KeychainStore(service: keychainService, account: keychainAccount)
        let stored = (try? keychain.read()) ?? ""
        self.initialAPIKey = stored
        self.apiKey = stored
        self.engineViewState = EngineSettingsViewState.make(
            selectedEngine: initial.engineMode,
            cloudKeyAvailable: stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            localStatus: .notDownloaded(modelID: engineReadiness.localModelID()),
            modelID: engineReadiness.localModelID()
        )
        Task { await refreshEngineViewState() }
    }

    var currentSettings: SessionSettings {
        SessionSettings(
            outputRoot: outputRoot,
            engineMode: engineMode,
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


    func refreshEngineViewState() async {
        engineViewState = await EngineSettingsViewState.make(selectedEngine: engineMode, readiness: engineReadiness)
    }

    func attemptEngineSelection(_ requestedMode: EngineMode) async -> EngineSelectionAttempt {
        await refreshEngineViewState()
        let attempt = await EngineSelectionPolicy.evaluate(
            requested: requestedMode,
            current: engineMode,
            readiness: engineReadiness
        )
        engineMode = attempt.selectedEngineMode
        await refreshEngineViewState()
        if let reason = attempt.repairReason {
            saveError = SettingsFormModel.repairMessage(for: reason)
        } else {
            saveError = nil
        }
        return attempt
    }

    @discardableResult
    func handleEngineAction(_ action: EngineSettingsAction) async -> EngineSettingsEffect {
        var reducer = EngineSettingsActionReducer(selectedEngine: engineMode)
        let effect = reducer.handle(action)
        engineMode = reducer.selectedEngine
        switch effect {
        case .confirmRemoveLocalModel:
            pendingLocalModelRemoval = effect
        case .startLocalRetry:
            _ = await onRetryLocalModel()
            await refreshEngineViewState()
            saveError = "Cohere model download is retrying."
        case .clearLocalModelCache:
            do {
                try await onClearLocalModelCache()
                pendingLocalModelRemoval = nil
                if engineMode == .local {
                    saveError = "Cohere model removed. Local remains selected and will show Setup Required until repaired."
                } else {
                    saveError = "Cohere model removed. Local will be unavailable until repaired."
                }
                await refreshEngineViewState()
            } catch {
                saveError = "Failed to remove Cohere model: \(error.localizedDescription)"
            }
        case .none:
            pendingLocalModelRemoval = nil
        }
        return effect
    }

    static func repairMessage(for reason: PreflightReason) -> String {
        switch reason {
        case .missingCloudAPIKey:
            return "Add an ElevenLabs API key before selecting Cloud."
        case .localRuntimeUnavailable:
            return "Cohere (local) is not supported on this Mac."
        case .localModelNotVerified:
            return "Cohere (local) is unavailable until the model is downloaded and verified."
        default:
            return "This engine is not ready yet. Fix setup before selecting it."
        }
    }

    var cloudAPIKeyHasChanges: Bool {
        apiKey != initialAPIKey
    }

    var cloudAPIKeyStatusText: String {
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No key saved"
        }
        return cloudAPIKeyHasChanges ? "Unsaved key edit" : "Key saved in Keychain"
    }

    /// Commits the API key through Keychain. Returns true on success.
    /// Pass a `keychainOverride` for testing with a fake seam; production
    /// always uses `KeychainStore(service:account:)`.
    @discardableResult
    func persistAPIKeyIfChanged(keychainOverride: (any KeychainPersisting)? = nil) async -> Bool {
        guard apiKey != initialAPIKey else { return true }
        isSavingCloudAPIKey = true
        defer { isSavingCloudAPIKey = false }
        let candidate = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let keychain: any KeychainPersisting = keychainOverride
            ?? KeychainStore(service: keychainService, account: keychainAccount)
        do {
            if candidate.isEmpty {
                try keychain.delete()
                apiKey = ""
                initialAPIKey = ""
                saveError = "ElevenLabs API key cleared. Cloud will show Setup Required until a key is saved."
            } else {
                try keychain.write(candidate)
                apiKey = candidate
                initialAPIKey = candidate
                saveError = "ElevenLabs API key saved to Keychain."
            }
            apiKeyEditedFromInitial = false
            await refreshEngineViewState()
            return true
        } catch {
            saveError = "Could not update the ElevenLabs API key in Keychain. The key was not saved; try again from Settings."
            return false
        }
    }

    @discardableResult
    func clearCloudAPIKey(keychainOverride: (any KeychainPersisting)? = nil) async -> Bool {
        apiKey = ""
        apiKeyEditedFromInitial = true
        return await persistAPIKeyIfChanged(keychainOverride: keychainOverride)
    }

    func canCloseOrSurfaceUnsavedCloudKeyWarning() -> Bool {
        guard cloudAPIKeyHasChanges else { return true }
        saveError = "Save or clear the ElevenLabs API key before closing Settings. Unsaved key edits stay only in this secure field."
        return false
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
    let initialEngineFocus: EngineSettingsCardFocus?
    @State private var selectedPage: SettingsPage = .general
    @State private var focusedEngineCard: EngineSettingsCardFocus?

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
        .onAppear {
            if let initialEngineFocus {
                selectedPage = .audio
                focusedEngineCard = initialEngineFocus
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsEngineFocusRequested)) { notification in
            selectedPage = .audio
            if let raw = notification.object as? String {
                focusedEngineCard = EngineSettingsCardFocus(rawValue: raw)
            }
        }
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
            FidelityAudioPanel(model: model, onSettingsChange: onSettingsChange, focusedEngineCard: focusedEngineCard)
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

private extension Notification.Name {
    static let settingsEngineFocusRequested = Notification.Name("ScribeSettingsEngineFocusRequested")
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

    static let font = "Inter Variable"
    static let rust = SwiftUI.Color(red: 235 / 255, green: 94 / 255, blue: 69 / 255)
    static let green = SwiftUI.Color(red: 89 / 255, green: 196 / 255, blue: 117 / 255)
    static let amber = SwiftUI.Color(red: 247 / 255, green: 184 / 255, blue: 61 / 255)
    static let surfaceWarmTint = adaptive(
        dark: NSColor(calibratedRed: 92 / 255, green: 28 / 255, blue: 18 / 255, alpha: 1.0),
        light: NSColor(calibratedRed: 255 / 255, green: 224 / 255, blue: 214 / 255, alpha: 1.0)
    )
    static let ink = adaptive(
        dark: NSColor(calibratedWhite: 250 / 255, alpha: 1.0),
        light: NSColor(calibratedWhite: 20 / 255, alpha: 1.0)
    )
    static let inkInverse = adaptive(
        dark: NSColor(calibratedWhite: 20 / 255, alpha: 1.0),
        light: NSColor(calibratedWhite: 250 / 255, alpha: 1.0)
    )
    static let ink2 = adaptive(
        dark: NSColor(calibratedWhite: 184 / 255, alpha: 1.0),
        light: NSColor(calibratedWhite: 71 / 255, alpha: 1.0)
    )
    static let ink3 = adaptive(
        dark: NSColor(calibratedWhite: 122 / 255, alpha: 1.0),
        light: NSColor(calibratedWhite: 107 / 255, alpha: 1.0)
    )
    static let line = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 15 / 255),
        light: NSColor(calibratedWhite: 0.0, alpha: 20 / 255)
    )
    static let lineRow = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 13 / 255),
        light: NSColor(calibratedWhite: 0.0, alpha: 18 / 255)
    )
    static let lineStrong = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 26 / 255),
        light: NSColor(calibratedWhite: 0.0, alpha: 31 / 255)
    )
    static let groupFill = adaptive(
        dark: NSColor(calibratedWhite: 1.0, alpha: 6 / 255),
        light: NSColor(calibratedWhite: 1.0, alpha: 158 / 255)
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
        dark: NSColor(calibratedWhite: 1.0, alpha: 10 / 255),
        light: NSColor(calibratedWhite: 1.0, alpha: 179 / 255)
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
            glassTint
            topRightGlow
            topLeftGlow
        }
    }

    private var isLight: Bool { colorScheme == .light }

    private var glassTint: SwiftUI.Color {
        isLight
            ? SwiftUI.Color(red: 245 / 255, green: 247 / 255, blue: 250 / 255)
            : SwiftUI.Color(red: 7 / 255, green: 1 / 255, blue: 3 / 255)
    }

    private var topRightGlow: RadialGradient {
        RadialGradient(
            colors: [
                isLight
                    ? SwiftUI.Color(red: 220 / 255, green: 234 / 255, blue: 251 / 255).opacity(0.55)
                    : SwiftUI.Color(red: 77 / 255, green: 13 / 255, blue: 26 / 255).opacity(0.55),
                SwiftUI.Color.clear
            ],
            center: UnitPoint(x: 0.82, y: 0.04),
            startRadius: 0,
            endRadius: 520
        )
    }

    private var topLeftGlow: RadialGradient {
        RadialGradient(
            colors: [
                isLight
                    ? SwiftUI.Color(red: 255 / 255, green: 224 / 255, blue: 214 / 255).opacity(0.42)
                    : SwiftUI.Color(red: 92 / 255, green: 28 / 255, blue: 18 / 255).opacity(0.42),
                SwiftUI.Color.clear
            ],
            center: UnitPoint(x: 0.05, y: 0.02),
            startRadius: 0,
            endRadius: 480
        )
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
            Text("Scribe records audio locally and saves transcripts to your Mac. Local (Cohere) transcription keeps everything on-device. Cloud (ElevenLabs) uploads audio to ElevenLabs for transcription.")
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
    let focusedEngineCard: EngineSettingsCardFocus?
    @State private var inputDevice = "MacBook Pro Microphone"
    @State private var language = "English (auto-detect dialect)"
    @State private var speakerLabels = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FidelityPanelIntro(
                title: "Audio",
                subtitle: "Configure how Scribe captures and transcribes voice."
            )

            FidelitySection(title: "Engine") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 10) {
                            FidelityEngineCard(
                                title: "ElevenLabs (cloud)",
                                status: model.engineViewState.cloud.statusText,
                                detail: model.engineViewState.cloud.detailText,
                                selected: model.engineMode == .cloud,
                                enabled: model.engineViewState.cloud.isSelectionEnabled,
                                actions: [],
                                focused: focusedEngineCard == .cloud
                            ) { selectEngine(.cloud) }
                            FidelityCloudAPIKeyEditor(
                                model: model,
                                focused: focusedEngineCard == .cloud,
                                onCommitSettings: onSettingsChange
                            )
                        }

                        FidelityEngineCard(
                            title: "Cohere (local)",
                            status: model.engineViewState.local.statusText,
                            detail: "\(model.engineViewState.local.modelName) · \(model.engineViewState.local.diskUsageText)\n\(model.engineViewState.local.privacyCopy)",
                            selected: model.engineMode == .local,
                            enabled: model.engineViewState.local.isSelectionEnabled,
                            actions: model.engineViewState.local.availableActions.map { action in
                                action == .retry ? "Retry" : "Remove"
                            },
                            focused: focusedEngineCard == .local
                        ) { selectEngine(.local) } actionHandler: { title in
                            Task {
                                if title == "Retry" { _ = await model.handleEngineAction(.retryLocalSetup) }
                                if title == "Remove" { _ = await model.handleEngineAction(.requestRemoveLocalModel) }
                            }
                        }
                    }
                    if case .confirmRemoveLocalModel(let modelName) = model.pendingLocalModelRemoval {
                        FidelityInlineConfirmation(
                            title: "Remove \(modelName)?",
                            message: "Local transcription will be unavailable until the Cohere model is downloaded and verified again.",
                            confirmTitle: "Remove",
                            onCancel: { Task { _ = await model.handleEngineAction(.cancelRemoveLocalModel) } },
                            onConfirm: { Task { _ = await model.handleEngineAction(.confirmRemoveLocalModel) } }
                        )
                    }
                }
                .padding(14)
                .task { await model.refreshEngineViewState() }
            }
            .padding(.bottom, 22)

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

    private func selectEngine(_ mode: EngineMode) {
        Task {
            let attempt = await model.attemptEngineSelection(mode)
            if attempt.accepted {
                await onSettingsChange(model.currentSettings)
            }
        }
    }

    private func persistSettings() {
        Task { await onSettingsChange(model.currentSettings) }
    }
}

private struct FidelityCloudAPIKeyEditor: View {
    @ObservedObject var model: SettingsFormModel
    let focused: Bool
    /// Called after a successful Save key or Clear key to commit any
    /// concurrent non-secret Settings edits via the shared save path.
    /// Keychain persistence always completes first; this is only invoked
    /// on success so Settings remains open on Keychain failure.
    let onCommitSettings: @MainActor (SessionSettings) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("ElevenLabs API key")
                .font(FidelitySettings.controlFont)
                .foregroundStyle(FidelitySettings.ink)
            SecureField("Paste API key", text: Binding(
                get: { model.apiKey },
                set: { value in
                    model.apiKey = value
                    model.apiKeyEditedFromInitial = true
                }
            ))
            .textFieldStyle(.plain)
            .font(FidelitySettings.rowValueFont)
            .foregroundStyle(FidelitySettings.ink)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(FidelitySettings.fieldFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(focused ? FidelitySettings.accentFocus : FidelitySettings.controlStroke, lineWidth: focused ? 2 : 1)
            )
            .accessibilityLabel("ElevenLabs API key")
            .accessibilityHint("Secure field. The key is saved only in macOS Keychain and is never shown in labels.")
            .accessibilityValue(model.cloudAPIKeyHasChanges ? "Unsaved changes" : model.cloudAPIKeyStatusText)

            Text("Save or clear the key explicitly. Scribe stores it only in macOS Keychain.")
                .font(SwiftUI.Font.custom(FidelitySettings.font, size: 11.5))
                .foregroundStyle(FidelitySettings.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("ElevenLabs key storage help")

            HStack(spacing: 8) {
                FidelitySecondaryButton(model.isSavingCloudAPIKey ? "Saving…" : "Save key") {
                    Task {
                        // Keychain-first: persist key before committing
                        // non-secret settings. On failure, stay open.
                        let ok = await model.persistAPIKeyIfChanged()
                        if ok { await onCommitSettings(model.currentSettings) }
                    }
                }
                .disabled(model.isSavingCloudAPIKey || !model.cloudAPIKeyHasChanges)
                .accessibilityLabel("Save ElevenLabs API key")
                .accessibilityHint("Saves the typed key to macOS Keychain before Cloud readiness refreshes.")

                FidelityDangerButton("Clear key") {
                    Task {
                        // Keychain-first: delete key before committing
                        // non-secret settings. On failure, stay open.
                        let ok = await model.clearCloudAPIKey()
                        if ok { await onCommitSettings(model.currentSettings) }
                    }
                }
                .disabled(model.isSavingCloudAPIKey || model.apiKey.isEmpty)
                .accessibilityLabel("Clear ElevenLabs API key")
                .accessibilityHint("Deletes the saved ElevenLabs API key from macOS Keychain.")

                Text(model.cloudAPIKeyStatusText)
                    .font(SwiftUI.Font.custom(FidelitySettings.font, size: 11.5))
                    .foregroundStyle(model.cloudAPIKeyHasChanges ? FidelitySettings.amber : FidelitySettings.ink3)
                    .accessibilityLabel("ElevenLabs API key status")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(FidelitySettings.fieldFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(focused ? FidelitySettings.accentFocus : FidelitySettings.controlStroke, lineWidth: focused ? 2 : 1)
        )
    }
}

private struct FidelityEngineCard: View {
    let title: String
    let status: String
    let detail: String
    let selected: Bool
    let enabled: Bool
    let actions: [String]
    let focused: Bool
    let select: () -> Void
    let actionHandler: (String) -> Void

    init(
        title: String,
        status: String,
        detail: String,
        selected: Bool,
        enabled: Bool,
        actions: [String],
        focused: Bool = false,
        select: @escaping () -> Void,
        actionHandler: @escaping (String) -> Void = { _ in }
    ) {
        self.title = title
        self.status = status
        self.detail = detail
        self.selected = selected
        self.enabled = enabled
        self.actions = actions
        self.focused = focused
        self.select = select
        self.actionHandler = actionHandler
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        FidelityStatusDot(color: selected ? FidelitySettings.green : (enabled ? FidelitySettings.amber : FidelitySettings.ink3))
                        Text(title)
                            .font(FidelitySettings.controlFont)
                            .foregroundStyle(selected ? FidelitySettings.ink : FidelitySettings.ink2)
                        Spacer(minLength: 0)
                        Text(status)
                            .font(SwiftUI.Font.custom(FidelitySettings.font, size: 11).weight(.medium))
                            .foregroundStyle(enabled ? FidelitySettings.green : FidelitySettings.amber)
                    }
                    Text(detail)
                        .font(SwiftUI.Font.custom(FidelitySettings.font, size: 11.5))
                        .foregroundStyle(FidelitySettings.ink3)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected ? FidelitySettings.controlSelected : FidelitySettings.fieldFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(focused ? FidelitySettings.accentFocus : (selected ? FidelitySettings.controlSelectedStroke : FidelitySettings.controlStroke), lineWidth: focused ? 2 : 1)
                )
                .opacity(enabled || selected ? 1 : 0.70)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)

            if actions.isEmpty == false {
                HStack(spacing: 8) {
                    ForEach(actions, id: \.self) { action in
                        if action == "Remove" {
                            FidelityDangerButton(action) { actionHandler(action) }
                        } else {
                            FidelitySecondaryButton(action) { actionHandler(action) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct FidelityInlineConfirmation: View {
    let title: String
    let message: String
    let confirmTitle: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(FidelitySettings.rowFont.weight(.medium))
                    .foregroundStyle(FidelitySettings.ink)
                Text(message)
                    .font(SwiftUI.Font.custom(FidelitySettings.font, size: 11.5))
                    .foregroundStyle(FidelitySettings.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            FidelityGhostButton("Cancel", action: onCancel)
            FidelityDangerButton(confirmTitle, action: onConfirm)
        }
        .padding(12)
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

private struct FidelityShortcutsPanel: View {
    @ObservedObject var model: SettingsFormModel
    let onShortcutChange: @MainActor (KeyboardShortcutSetting) -> Void
    let onSettingsChange: @MainActor (SessionSettings) async -> Void
    @State private var menuShortcut = KeyboardShortcutSetting(key: "S", keyCode: 1, modifiers: [.control, .command])

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
                subtitle: "Audio files always stay on your Mac. Local (Cohere) transcription keeps everything on-device. Cloud (ElevenLabs) uploads mixed audio to ElevenLabs; when Calendar access is granted and a matching event exists, title and attendee keyterms may also be sent."
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

/// Backing state for the polished Permissions panel. Shared between the
/// Settings tab (one-shot refresh) and the standalone Permissions
/// onboarding window (auto-poll + becomes-active observer). The model
/// owns the four permission statuses, the request handlers that fire
/// in-app system prompts, and the screen-recording restart-required
/// signal that AppDelegate maps to the relaunch alert.
struct DebugPermissionStatuses {
    let microphone: PermissionStatus
    let screenRecording: PermissionStatus
    let calendar: PermissionStatus
    let notifications: PermissionStatus

    var allRequiredGranted: Bool {
        microphone == .granted && screenRecording == .granted
    }

    static let withoutPermissions = DebugPermissionStatuses(
        microphone: .notDetermined,
        screenRecording: .denied,
        calendar: .notDetermined,
        notifications: .notDetermined
    )

    static let withPermissions = DebugPermissionStatuses(
        microphone: .granted,
        screenRecording: .granted,
        calendar: .granted,
        notifications: .granted
    )
}

@MainActor
final class PermissionsPanelModel: ObservableObject {
    @Published var microphoneStatus: PermissionStatus = .notDetermined
    @Published var screenRecordingStatus: PermissionStatus = .notDetermined
    @Published var calendarStatus: PermissionStatus = .notDetermined
    @Published var notificationStatus: PermissionStatus = .notDetermined

    /// True when every "Required" permission is granted (Mic + Screen
    /// Recording). The onboarding window's Done button gates on this so
    /// the user can't dismiss before fixing the blockers.
    var allRequiredGranted: Bool {
        microphoneStatus == .granted && screenRecordingStatus == .granted
    }

    /// Fires when `requestScreenRecording()` reports access granted but
    /// `screenRecordingStatus()` still returns denied — the macOS quirk
    /// where TCC propagation requires a process restart. AppDelegate
    /// owns the relaunch alert; the model just surfaces the signal.
    var onScreenRecordingRestartRequired: (@MainActor () -> Void)?

    private let permissions: PermissionsService
    private let autoPoll: Bool
    private let debugStatuses: DebugPermissionStatuses?
    private var refreshTimer: Timer?
    private var didBecomeActiveObserver: NSObjectProtocol?

    init(
        autoPoll: Bool,
        permissions: PermissionsService = PermissionsService(),
        debugStatuses: DebugPermissionStatuses? = nil
    ) {
        self.autoPoll = autoPoll
        self.permissions = permissions
        self.debugStatuses = debugStatuses
        if let debugStatuses {
            microphoneStatus = debugStatuses.microphone
            screenRecordingStatus = debugStatuses.screenRecording
            calendarStatus = debugStatuses.calendar
            notificationStatus = debugStatuses.notifications
        }
    }

    // No deinit cleanup: Swift 6 forbids reaching the MainActor-isolated
    // `refreshTimer` / `didBecomeActiveObserver` from a nonisolated
    // deinit. The Timer captures `[weak self]` so it auto-no-ops after
    // dealloc; observer leak is bounded by call sites invoking `stop()`
    // (the SwiftUI view's `onDisappear` does this).

    /// Kick off one immediate refresh, then (when `autoPoll`) the 1.5s
    /// poll and the becomes-active observer. The poll cadence matches
    /// what the deprecated popover used; TCC has no change-notification
    /// API for these scopes so polling is the cheap fallback.
    func start() {
        if debugStatuses != nil { return }
        Task { @MainActor [weak self] in
            await self?.refreshStatuses()
        }
        guard autoPoll else { return }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshStatuses()
            }
        }
        if didBecomeActiveObserver == nil {
            didBecomeActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.refreshStatuses()
                }
            }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let token = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(token)
            didBecomeActiveObserver = nil
        }
    }

    func refreshStatuses() async {
        if let debugStatuses {
            microphoneStatus = debugStatuses.microphone
            screenRecordingStatus = debugStatuses.screenRecording
            calendarStatus = debugStatuses.calendar
            notificationStatus = debugStatuses.notifications
            return
        }
        let probe = DefaultPermissionStatusProbe(permissions: permissions)
        async let mic = probe.microphone()
        async let screen = probe.screenRecording()
        async let cal = probe.calendar()
        async let notif = notificationPermissionStatus()
        microphoneStatus = await mic
        screenRecordingStatus = await screen
        calendarStatus = await cal
        notificationStatus = await notif
    }

    func requestMicrophone() async {
        _ = await permissions.requestMicrophone()
        await refreshStatuses()
    }

    func requestScreenRecording() async {
        let granted = await permissions.requestScreenRecording()
        await refreshStatuses()
        if granted, screenRecordingStatus == .denied {
            onScreenRecordingRestartRequired?()
        }
    }

    func requestCalendar() async {
        _ = await permissions.requestCalendar()
        await refreshStatuses()
    }

    func requestNotifications() async {
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
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}

/// Shared permissions panel content rendered by both the Settings tab
/// and the standalone Permissions onboarding window. Owns its panel
/// model so each surface has its own polling state. Dynamic per-status
/// buttons: `.notDetermined` → in-app Allow…, `.denied` → deep-link to
/// System Settings, `.granted` → no button (status pill carries it).
private struct FidelityPermissionsPanel: View {
    @StateObject private var model: PermissionsPanelModel
    private let title: String
    private let subtitle: String
    private let renderIntro: Bool
    private let showsBypassExplainer: Bool

    private let onRequiredStateChanged: ((Bool) -> Void)?

    init(
        title: String = "Permissions",
        subtitle: String = "Grant a few macOS permissions to capture meetings. Audio stays on your Mac. You can change access anytime in System Settings.",
        autoPoll: Bool = false,
        renderIntro: Bool = true,
        showsBypassExplainer: Bool = false,
        onScreenRecordingRestartRequired: (@MainActor () -> Void)? = nil,
        onRequiredStateChanged: ((Bool) -> Void)? = nil,
        debugStatuses: DebugPermissionStatuses? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.renderIntro = renderIntro
        self.showsBypassExplainer = showsBypassExplainer
        self.onRequiredStateChanged = onRequiredStateChanged
        let panel = PermissionsPanelModel(
            autoPoll: autoPoll,
            debugStatuses: debugStatuses
        )
        panel.onScreenRecordingRestartRequired = onScreenRecordingRestartRequired
        _model = StateObject(wrappedValue: panel)
    }

    private struct RowSpec: Identifiable {
        let id: String
        let title: String
        let help: String
        let statusKey: KeyPath<PermissionsPanelModel, PermissionStatus>
        let request: @MainActor () async -> Void
        let systemPane: String
    }

    private var requiredRowSpecs: [RowSpec] {
        [
            RowSpec(
                id: "microphone",
                title: "Microphone",
                help: "Records your side of the meeting.",
                statusKey: \.microphoneStatus,
                request: { await model.requestMicrophone() },
                systemPane: "Privacy_Microphone"
            ),
            RowSpec(
                id: "screenRecording",
                title: "Screen Recording",
                help: "Captures everyone else. No video.",
                statusKey: \.screenRecordingStatus,
                request: { await model.requestScreenRecording() },
                systemPane: "Privacy_ScreenCapture"
            ),
        ]
    }

    private var recommendedRowSpecs: [RowSpec] {
        [
            RowSpec(
                id: "calendar",
                title: "Calendar",
                help: "Names transcripts and labels speakers.",
                statusKey: \.calendarStatus,
                request: { await model.requestCalendar() },
                systemPane: "Privacy_Calendars"
            ),
            RowSpec(
                id: "notifications",
                title: "Notifications",
                help: "Alerts you when a transcript is ready.",
                statusKey: \.notificationStatus,
                request: { await model.requestNotifications() },
                systemPane: "Privacy_Notifications"
            ),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if renderIntro {
                FidelityPanelIntro(title: title, subtitle: subtitle)
            }

            permissionsSection(title: "Required", specs: requiredRowSpecs)
                .padding(.bottom, 24)

            permissionsSection(title: "Recommended", specs: recommendedRowSpecs)
                .padding(.bottom, showsBypassExplainer ? 14 : 0)

            if showsBypassExplainer {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(FidelitySettings.ink3)
                        .padding(.top, 2)
                    Text("macOS may occasionally ask Scribe to bypass the system private window picker — say Allow. It's how Scribe captures system audio without picking a window each time.")
                        .font(SwiftUI.Font.custom(FidelitySettings.font, size: 11.5))
                        .foregroundStyle(FidelitySettings.ink3)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
            }
        }
        .task {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
        .onChange(of: model.microphoneStatus) { _, _ in
            onRequiredStateChanged?(model.allRequiredGranted)
        }
        .onChange(of: model.screenRecordingStatus) { _, _ in
            onRequiredStateChanged?(model.allRequiredGranted)
        }
    }

    // ForEach (vs an inline TupleView) is the defensive choice: tuple
    // builders are fine up to 10 children, but a previous inline version
    // rendered only the first rows in some builds (suspected first-paint
    // race against the @StateObject's async refresh). ForEach with stable
    // IDs forces SwiftUI to diff per-row instead of treating the whole
    // section as one opaque tuple.
    @ViewBuilder
    private func permissionsSection(title: String, specs: [RowSpec]) -> some View {
        FidelitySection(title: title) {
            ForEach(Array(specs.enumerated()), id: \.element.id) { index, spec in
                if index > 0 {
                    FidelityRowDivider()
                }
                FidelityPermissionRow(
                    title: spec.title,
                    status: model[keyPath: spec.statusKey],
                    help: spec.help,
                    action: rowAction(
                        for: model[keyPath: spec.statusKey],
                        request: spec.request,
                        systemPane: spec.systemPane
                    )
                )
            }
        }
    }

    private func rowAction(
        for status: PermissionStatus,
        request: @escaping @MainActor () async -> Void,
        systemPane: String
    ) -> FidelityPermissionAction? {
        switch status {
        case .granted:
            return nil
        case .notDetermined:
            return .secondary("Allow") {
                Task { @MainActor in await request() }
            }
        case .denied:
            return .systemSettings {
                Self.openSystemSettings(systemPane)
            }
        }
    }

    private static func openSystemSettings(_ pane: String) {
        // Screen Recording quirk: macOS only lists an app in the
        // "Screen & System Audio Recording" toggle list once it has
        // called CGRequestScreenCaptureAccess at least once. On a fresh
        // install or after `tccutil reset` Scribe is missing from the
        // list entirely — the user opens Settings and there's no row to
        // flip. Register first so the row exists when Settings opens.
        // No-op if already granted; returns immediately without a prompt
        // if previously denied.
        if pane == "Privacy_ScreenCapture" {
            _ = CGRequestScreenCaptureAccess()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
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
    /// `nil` when no action is appropriate (e.g., status == .granted).
    /// The row still renders title, status pill, and description; the
    /// button column collapses so the row stays balanced.
    let action: FidelityPermissionAction?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(status.fidelityColor)
                .frame(width: 8, height: 8)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(title)
                        .font(FidelitySettings.rowFont.weight(.medium))
                        .foregroundStyle(FidelitySettings.ink)
                        .tracking(-0.08)
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
            if let action {
                FidelityPermissionButton(action: action)
                    .padding(.top, 2)
            } else if status == .granted {
                FidelityGrantedIndicator()
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

private struct FidelityGrantedIndicator: View {
    var body: some View {
        HStack(spacing: 4) {
            LucideIcon(glyph: .check)
                .frame(width: 12, height: 12)
                .foregroundStyle(FidelitySettings.green)
            Text("Granted")
                .font(SwiftUI.Font.custom(FidelitySettings.font, size: 12.5).weight(.medium))
                .foregroundStyle(FidelitySettings.ink3)
        }
        .frame(height: 28)
        .padding(.horizontal, 8)
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
                    .font(SwiftUI.Font.custom(FidelitySettings.font, size: 12.5)
                        .weight(action.isSystemSettings ? .medium : .semibold))
                if action.isSystemSettings {
                    LucideIcon(glyph: .arrowUpRight)
                        .frame(width: 10.5, height: 10.5)
                        .opacity(0.58)
                }
            }
            .foregroundStyle(action.isSystemSettings ? FidelitySettings.ink2 : FidelitySettings.inkInverse)
            .padding(.horizontal, action.isSystemSettings ? 8 : 14)
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
                .fill(FidelitySettings.ink)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(SwiftUI.Color.black.opacity(0.08), lineWidth: 1)
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
    let detail: String?
    @ViewBuilder var content: () -> Content

    init(title: String, detail: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(title.uppercased())
                    .font(FidelitySettings.sectionFont)
                    .foregroundStyle(FidelitySettings.ink3)
                    .tracking(0.66)
                Spacer(minLength: 0)
                if let detail {
                    Text(detail)
                        .font(SwiftUI.Font.custom(FidelitySettings.font, size: 11).weight(.medium))
                        .foregroundStyle(FidelitySettings.ink3)
                        .tracking(-0.05)
                }
            }
            .padding(.horizontal, 14)
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

private struct FidelityDangerButton: View {
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
                .foregroundStyle(SwiftUI.Color.white)
                .frame(height: 28)
                .padding(.horizontal, 11)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(FidelitySettings.rust)
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

/// Standalone Permissions window shown when Record is blocked by
/// missing permissions, or from the menu bar's "Setup Required..."
/// entry. Hosts the same `FidelityPermissionsPanel` content as the
/// Settings tab but in a focused, no-sidebar window with auto-polling
/// so grants made in System Settings reflect within ~1.5s when the
/// user comes back.
///
/// Replaces the deprecated `PermissionRecoveryPopoverController`
/// (menu-bar popover) which had a flashing/dismissal bug and only
/// showed unmet permissions; the window shows all four with status
/// pills so the user has a complete picture.
@MainActor
final class PermissionsOnboardingWindowController {
    private var window: NSWindow?
    private var windowDelegate: WindowDelegate?
    private let onScreenRecordingRestartRequired: @MainActor () -> Void

    init(onScreenRecordingRestartRequired: @escaping @MainActor () -> Void) {
        self.onScreenRecordingRestartRequired = onScreenRecordingRestartRequired
    }

    var isShown: Bool { window?.isVisible == true }

    func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Borderless + transparent background gives the SwiftUI
        // FidelityWindowSurface gradient an edge-to-edge canvas with no
        // standard macOS title bar consuming the top strip. The
        // SwiftUI body draws its own close affordance (the Done button)
        // and the close button is rendered as a hosted control in the
        // hero area; `isMovableByWindowBackground` lets the user drag
        // anywhere on the window.
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.title = "Scribe Setup"
        host.titleVisibility = .hidden
        host.titlebarAppearsTransparent = true
        host.isOpaque = false
        host.backgroundColor = .clear
        host.isMovableByWindowBackground = true
        host.center()
        host.isReleasedWhenClosed = false
        host.sharingType = WindowChromeSharing.confidential
        host.collectionBehavior.insert(.moveToActiveSpace)

        host.contentView = NSHostingView(rootView: PermissionsOnboardingView(
            onScreenRecordingRestartRequired: { [weak self] in
                self?.onScreenRecordingRestartRequired()
            },
            onClose: { [weak self] in
                self?.close()
            }
        ))
        WindowChrome.installGlass(on: host, material: .hudWindow)
        if let contentView = host.contentView {
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
            contentView.layer?.cornerRadius = 14
            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.masksToBounds = true
        }

        let delegate = WindowDelegate { [weak self] in
            self?.window = nil
            self?.windowDelegate = nil
        }
        host.delegate = delegate

        host.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = host
        self.windowDelegate = delegate
    }

    func close() {
        window?.close()
        window = nil
        windowDelegate = nil
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate, @unchecked Sendable {
        let onClose: @MainActor () -> Void
        init(onClose: @escaping @MainActor () -> Void) { self.onClose = onClose }
        func windowWillClose(_ notification: Notification) {
            Task { @MainActor in onClose() }
        }
    }
}

private struct PermissionsOnboardingTrafficLight: View {
    let color: SwiftUI.Color
    let action: (@MainActor () -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            Circle()
                .fill(color)
                .overlay(
                    Circle()
                        .strokeBorder(SwiftUI.Color.black.opacity(0.078), lineWidth: 0.5)
                )
                .frame(width: 12, height: 12)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .help(action == nil ? "" : "Close")
    }
}

private struct PermissionsOnboardingView: View {
    let onScreenRecordingRestartRequired: @MainActor () -> Void
    let onClose: @MainActor () -> Void
    #if DEBUG
    let debugPermissionStatuses: DebugPermissionStatuses?
    #endif
    @State private var requiredGranted: Bool

    #if DEBUG
    init(
        onScreenRecordingRestartRequired: @escaping @MainActor () -> Void,
        onClose: @escaping @MainActor () -> Void,
        debugPermissionStatuses: DebugPermissionStatuses? = nil
    ) {
        self.onScreenRecordingRestartRequired = onScreenRecordingRestartRequired
        self.onClose = onClose
        self.debugPermissionStatuses = debugPermissionStatuses
        _requiredGranted = State(initialValue: debugPermissionStatuses?.allRequiredGranted ?? false)
    }
    #else
    init(
        onScreenRecordingRestartRequired: @escaping @MainActor () -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.onScreenRecordingRestartRequired = onScreenRecordingRestartRequired
        self.onClose = onClose
        _requiredGranted = State(initialValue: false)
    }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            VStack(alignment: .leading, spacing: 24) {
                hero
                // Mirror the Settings → Permissions tab so both
                // surfaces feel like the same family of UI. The
                // onboarding window builds its own hero + footer; the
                // panel renders just the section cards (renderIntro:
                // false), plus auto-poll so grants made in System
                // Settings reflect within ~1.5s.
                #if DEBUG
                FidelityPermissionsPanel(
                    autoPoll: true,
                    renderIntro: false,
                    showsBypassExplainer: false,
                    onScreenRecordingRestartRequired: onScreenRecordingRestartRequired,
                    onRequiredStateChanged: { granted in
                        requiredGranted = granted
                    },
                    debugStatuses: debugPermissionStatuses
                )
                #else
                FidelityPermissionsPanel(
                    autoPoll: true,
                    renderIntro: false,
                    showsBypassExplainer: false,
                    onScreenRecordingRestartRequired: onScreenRecordingRestartRequired,
                    onRequiredStateChanged: { granted in
                        requiredGranted = granted
                    }
                )
                #endif
                footer
            }
            .padding(.top, 12)
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 620, height: 620)
        .background(FidelityWindowSurface())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FidelitySettings.lineStrong, lineWidth: 1)
        )
    }

    // Borderless window chrome with custom 12×12 traffic light dots
    // matching the design. The close dot calls `onClose`; the
    // minimize/zoom dots are decorative-only (rendered gray to match
    // macOS's disabled-button look) because the onboarding window
    // should never be minimized or zoomed mid-setup.
    private var titleBar: some View {
        HStack(spacing: 8) {
            PermissionsOnboardingTrafficLight(
                color: SwiftUI.Color(red: 1.0, green: 0.373, blue: 0.341),
                action: onClose
            )
            PermissionsOnboardingTrafficLight(
                color: SwiftUI.Color(red: 0.851, green: 0.851, blue: 0.839),
                action: nil
            )
            PermissionsOnboardingTrafficLight(
                color: SwiftUI.Color(red: 0.851, green: 0.851, blue: 0.839),
                action: nil
            )
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .frame(height: 36)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(FidelitySettings.secondaryButtonFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        FidelitySettings.surfaceWarmTint.opacity(0.70),
                                        SwiftUI.Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(FidelitySettings.lineStrong, lineWidth: 1)
                    )
                    .shadow(color: SwiftUI.Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
                MenuHeaderMark()
                    .fill(FidelitySettings.ink)
                    .frame(width: 22, height: 22)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 6) {
                Text("Let's set up Scribe")
                    .font(SwiftUI.Font.custom(FidelitySettings.font, size: 24).weight(.semibold))
                    .foregroundStyle(FidelitySettings.ink)
                    .tracking(-0.6)
                Text("Grant a few macOS permissions to capture meetings.")
                    .font(FidelitySettings.subtitleFont)
                    .foregroundStyle(FidelitySettings.ink2)
                    .lineSpacing(4)
                    .tracking(-0.08)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 6) {
            LucideIcon(glyph: .info)
                .frame(width: 12, height: 12)
                .foregroundStyle(FidelitySettings.ink3)
            Text("You can change these anytime in System Settings.")
                .font(SwiftUI.Font.custom(FidelitySettings.font, size: 11.5))
                .foregroundStyle(FidelitySettings.ink3)
                .tracking(-0.05)
            Spacer(minLength: 0)
            Button {
                if requiredGranted {
                    onClose()
                }
            } label: {
                Text("Done")
                    .font(SwiftUI.Font.custom(FidelitySettings.font, size: 12.5).weight(.semibold))
                    .foregroundStyle(requiredGranted ? FidelitySettings.inkInverse : FidelitySettings.ink3)
                    .frame(height: 28)
                    .padding(.horizontal, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(requiredGranted ? FidelitySettings.ink : FidelitySettings.offToggleFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(requiredGranted ? SwiftUI.Color.black.opacity(0.08) : FidelitySettings.line, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!requiredGranted)
            .help(requiredGranted ? "Done" : "Grant Microphone and Screen Recording first")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
}

#if DEBUG
@MainActor
enum OnboardingVisualSnapshotRenderer {
    static func renderAll(to directory: URL) throws {
        let cases: [(name: String, statuses: DebugPermissionStatuses, colorScheme: ColorScheme)] = [
            ("onboarding-without-permissions-light", .withoutPermissions, .light),
            ("onboarding-with-permissions-light", .withPermissions, .light),
            ("onboarding-without-permissions-dark", .withoutPermissions, .dark),
            ("onboarding-with-permissions-dark", .withPermissions, .dark)
        ]

        for item in cases {
            let view = PermissionsOnboardingView(
                onScreenRecordingRestartRequired: {},
                onClose: {},
                debugPermissionStatuses: item.statuses
            )
            .environment(\.colorScheme, item.colorScheme)
            .preferredColorScheme(item.colorScheme)
            try DebugVisualSnapshotWriter.write(view, named: item.name, to: directory)
        }
    }
}
#endif
