import AppKit
import EventKit
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
    private var window: NSWindow?
    var onAppearanceThemeChange: (@MainActor (AppearanceTheme) -> Void)?

    init(
        store: SettingsStore,
        fallback: SettingsStore.Defaults,
        keychainService: String,
        keychainAccount: String
    ) {
        self.store = store
        self.fallback = fallback
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
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
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        host.title = "Scribe Settings"
        host.minSize = NSSize(width: 880, height: 600)
        host.maxSize = NSSize(width: 880, height: 600)
        host.center()
        host.isReleasedWhenClosed = false
        // Codex PM-review UX-4: confidential UI.
        host.sharingType = WindowChromeSharing.confidential
        host.contentView = NSHostingView(rootView: SettingsForm(
            model: model,
            onSave: { [weak self, weak host] settings in
                guard let self else { return }
                // Codex Phase η P1.1 + P1.2: actually await the commit
                // so encode failures surface to the user. Settings UI
                // stays open on error; closes only after success.
                do {
                    try await self.store.commit(settings)
                    self.onAppearanceThemeChange?(settings.appearanceTheme)
                    host?.close()
                    self.window = nil
                } catch {
                    model.saveError = "Failed to save settings: \(error.localizedDescription)"
                }
            },
            onCancel: { [weak self, weak host] in
                self?.onAppearanceThemeChange?(model.initialSnapshot.appearanceTheme)
                host?.close()
                self?.window = nil
            },
            onAppearanceThemeChange: { [weak self] theme in
                self?.onAppearanceThemeChange?(theme)
            }
        ))

        // Codex Phase η P1.3: a title-bar close should behave like
        // Cancel (drop the in-flight model + clear the window pointer
        // so the next open re-reads the on-disk snapshot fresh).
        let delegate = SettingsWindowDelegate { [weak self] in
            guard let self else { return }
            self.onAppearanceThemeChange?(SettingsSnapshotReader.read(fallback: self.fallback).appearanceTheme)
            self.window = nil
        }
        host.delegate = delegate
        objc_setAssociatedObject(host, &settingsWindowDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        WindowChrome.installGlass(on: host, material: .hudWindow)

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
    @Published var appearanceTheme: AppearanceTheme
    @Published var keepRawStreams: Bool
    @Published var aecEnabled: Bool
    @Published var apiKey: String
    @Published var apiKeyEditedFromInitial: Bool = false
    @Published var saveError: String?
    @Published var storageAudioBytes: Int64 = 0
    @Published var deleteAudioError: String?
    @Published var microphoneStatus: PermissionStatus = .notDetermined
    @Published var screenRecordingStatus: PermissionStatus = .notDetermined
    @Published var calendarStatus: PermissionStatus = .notDetermined
    @Published var notificationStatus: PermissionStatus = .notDetermined

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
        self.appearanceTheme = initial.appearanceTheme
        self.keepRawStreams = initial.keepRawStreams
        self.aecEnabled = initial.aecEnabled
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount

        let keychain = KeychainStore(service: keychainService, account: keychainAccount)
        let stored = (try? keychain.read()) ?? ""
        self.initialAPIKey = stored
        self.apiKey = stored
        refreshStorageUsage()
        refreshPermissionStatuses()
    }

    var currentSettings: SessionSettings {
        SessionSettings(
            outputRoot: outputRoot,
            // Codex PM-review UX-10: pin to cloud while local is
            // disabled in UI. Local mode shipped only as protocol +
            // EngineSelector dispatch; saving it would create a
            // dead-end recording failure.
            engineMode: .cloud,
            appearanceTheme: appearanceTheme,
            keepRawStreams: keepRawStreams,
            aecEnabled: aecEnabled,
            // Privacy ack is one-way; if the user already acked it,
            // preserve. The Settings UI doesn't let them un-ack.
            privacyAcknowledged: initialSnapshot.privacyAcknowledged
        )
    }

    /// Commits the API key through Keychain. Returns true on success.
    /// Caller drops `saveError` if non-nil so the form can surface it.
    func persistAPIKeyIfChanged() -> Bool {
        guard apiKey != initialAPIKey else { return true }
        let keychain = KeychainStore(service: keychainService, account: keychainAccount)
        do {
            if apiKey.isEmpty {
                try keychain.delete()
            } else {
                try keychain.write(apiKey)
            }
            return true
        } catch {
            self.saveError = "Failed to save API key: \(error.localizedDescription)"
            return false
        }
    }

    func refreshStorageUsage() {
        storageAudioBytes = Self.totalAudioBytes(under: outputRoot)
    }

    func refreshPermissionStatuses() {
        microphoneStatus = PermissionsService().microphoneStatus()
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            calendarStatus = .granted
        case .denied, .restricted:
            calendarStatus = .denied
        case .notDetermined, .authorized, .writeOnly:
            calendarStatus = .notDetermined
        @unknown default:
            calendarStatus = .notDetermined
        }
        Task { @MainActor in
            screenRecordingStatus = await PermissionsService().screenRecordingStatus()
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                notificationStatus = .granted
            case .denied:
                notificationStatus = .denied
            case .notDetermined:
                notificationStatus = .notDetermined
            @unknown default:
                notificationStatus = .notDetermined
            }
        }
    }

    func deleteAllAudioKeepingTranscripts() {
        do {
            try Self.deleteAudioFiles(under: outputRoot)
            deleteAudioError = nil
            refreshStorageUsage()
        } catch {
            deleteAudioError = "Failed to delete audio: \(error.localizedDescription)"
        }
    }

    static func totalAudioBytes(under root: URL) -> Int64 {
        let names = Set(["audio.m4a", "mic.m4a", "system.m4a"])
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        for case let url as URL in enumerator where names.contains(url.lastPathComponent) {
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    static func deleteAudioFiles(under root: URL) throws {
        let names = Set(["audio.m4a", "mic.m4a", "system.m4a"])
        guard let sessionDirs = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for dir in sessionDirs {
            guard let values = try? dir.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true else {
                continue
            }
            let transcript = dir.appendingPathComponent("transcript.md")
            guard let status = TranscriptStatusReader.read(at: transcript), status == .complete || status == .failed else {
                continue
            }
            for name in names {
                let audio = dir.appendingPathComponent(name)
                if let values = try? audio.resourceValues(forKeys: [.isRegularFileKey]),
                   values.isRegularFile == true {
                    try FileManager.default.removeItem(at: audio)
                }
            }
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
    let onSave: @MainActor (SessionSettings) async -> Void
    let onCancel: @MainActor () -> Void
    let onAppearanceThemeChange: (@MainActor (AppearanceTheme) -> Void)?
    @State private var saving: Bool = false
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selectedTab: $selectedTab)
                .frame(width: 200)
            Divider().background(SwiftUI.Color.white.opacity(0.06))
            VStack(spacing: 0) {
                head
                Divider().background(SwiftUI.Color.white.opacity(0.06))
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(selectedTab.title)
                                .font(SettingsDesign.title)
                                .foregroundStyle(DS.Color.foreground)
                            Text(selectedTab.subtitle)
                                .font(SettingsDesign.subtitle)
                                .foregroundStyle(DS.Color.foregroundSecondary)
                                .lineSpacing(2)
                                .frame(maxWidth: 520, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        tabContent
                    }
                    .padding(.horizontal, 36)
                    .padding(.top, 28)
                    .padding(.bottom, 36)
                }
            }
        }
        .frame(width: 880, height: 600)
        .background(SettingsWindowSurface())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .font(SettingsDesign.body)
        .onAppear {
            model.refreshStorageUsage()
            model.refreshPermissionStatuses()
        }
        .onChange(of: model.appearanceTheme) { theme in
            onAppearanceThemeChange?(theme)
        }
    }

    private var head: some View {
        HStack {
            Text("Settings")
                .font(SettingsDesign.headerTitle)
                .foregroundStyle(DS.Color.foreground)
            Spacer()
            if let err = model.saveError {
                HStack(spacing: 7) {
                    Indicator(state: .failed, label: "Error")
                    Text(err)
                        .font(SettingsDesign.caption)
                        .foregroundStyle(DS.Color.danger)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.trailing, 6)
            }
            Button("Discard", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(GhostButtonStyle())
                .disabled(saving)
            Button(saving ? "Saving…" : "Save") {
                Task { await save() }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(PrimaryButtonStyle())
            .hoverSheen()
            .disabled(saving)
        }
        .padding(.horizontal, 18)
        .frame(height: 38)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .general:
            GeneralSection(model: model)
            EngineSection(model: model)
        case .audio:
            AudioSection(model: model)
        case .storage:
            OutputSection(model: model)
            StorageSection(model: model)
        case .privacy:
            PrivacyStatusSection(model: model)
        case .permissions:
            PermissionsSection(model: model)
        case .about:
            AboutSection()
        }
    }

    @MainActor
    private func save() async {
        saving = true
        defer { saving = false }
        model.saveError = nil
        // Codex Phase η P1.2: keychain write THEN settings commit, both
        // awaited. If keychain fails, surface and abort. If settings
        // commit fails, the keychain key was already written; log the
        // partial state but keep the form open so the user can retry
        // (rolling back the keychain on commit failure could destroy a
        // good key the user just typed).
        guard model.persistAPIKeyIfChanged() else { return }
        await onSave(model.currentSettings)
    }
}

private struct SettingsWindowSurface: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(SwiftUI.Color(red: 0.10, green: 0.10, blue: 0.12).opacity(0.78))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(SwiftUI.Color.white.opacity(0.10), lineWidth: 1)
            )
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [SwiftUI.Color.clear, SwiftUI.Color.white.opacity(0.20), SwiftUI.Color.clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 1)
                .padding(.horizontal, 24)
            }
            .allowsHitTesting(false)
    }
}

private enum SettingsTab: CaseIterable, Identifiable {
    case general, audio, storage, privacy, permissions, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .audio: return "Audio"
        case .storage: return "Vault"
        case .privacy: return "Privacy"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Choose the transcription engine and configure Scribe's core behavior."
        case .audio: return "Control capture details for mic and system audio."
        case .storage: return "Pick where transcripts land and manage retained audio."
        case .privacy: return "Review how Scribe handles captured audio and metadata."
        case .permissions: return "Check the macOS permissions Scribe needs to capture meetings."
        case .about: return "Version and build details for this copy of Scribe."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .audio: return "waveform"
        case .storage: return "folder"
        case .privacy: return "lock"
        case .permissions: return "checkmark.shield"
        case .about: return "info.circle"
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selectedTab: SettingsTab

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 38)

            VStack(spacing: 1) {
                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedTab == tab ? DS.Color.recording : SwiftUI.Color.white.opacity(0.05))
                                Image(systemName: tab.symbol)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(selectedTab == tab ? SwiftUI.Color.white : DS.Color.foregroundTertiary)
                            }
                            .frame(width: 22, height: 22)
                            Text(tab.title)
                                .font(SettingsDesign.rowLabel)
                                .foregroundStyle(selectedTab == tab ? DS.Color.foreground : DS.Color.foregroundSecondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedTab == tab ? SwiftUI.Color.white.opacity(0.06) : SwiftUI.Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            Spacer()
        }
        .background(SwiftUI.Color.white.opacity(0.025))
    }
}

private enum SettingsDesign {
    static let family = "Inter"
    static let title = SwiftUI.Font.custom(family, size: 22).weight(.semibold).leading(.tight)
    static let subtitle = SwiftUI.Font.custom(family, size: 13).weight(.regular).leading(.standard)
    static let headerTitle = SwiftUI.Font.custom(family, size: 13).weight(.semibold)
    static let section = SwiftUI.Font.custom(family, size: 11).weight(.semibold)
    static let rowLabel = SwiftUI.Font.custom(family, size: 13).weight(.regular)
    static let rowValue = SwiftUI.Font.custom(family, size: 13).weight(.regular)
    static let rowEmphasis = SwiftUI.Font.custom(family, size: 13).weight(.medium)
    static let caption = SwiftUI.Font.custom(family, size: 11.5).weight(.regular)
    static let button = SwiftUI.Font.custom(family, size: 12.5).weight(.medium)
    static let body = SwiftUI.Font.custom(family, size: 13).weight(.regular)
}

private struct SettingsBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(SettingsDesign.section)
                .tracking(0.66)
                .foregroundStyle(DS.Color.foregroundTertiary)
                .padding(.leading, 14)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(SwiftUI.Color.white.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(SwiftUI.Color.white.opacity(0.06), lineWidth: 1)
            )
        }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(SwiftUI.Color.white.opacity(0.05))
            .frame(height: 1)
            .padding(.leading, 178)
    }
}

private struct GeneralSection: View {
    @ObservedObject var model: SettingsFormModel

    var body: some View {
        SettingsBox(title: "App") {
            DSStatusRow("Menu bar app") {
                HStack(spacing: 6) {
                    Indicator(state: .ready, label: "On")
                            Text("Scribe runs from the menu bar")
                        .font(SettingsDesign.rowValue)
                        .foregroundStyle(DS.Color.foregroundTertiary)
                }
            }
            SettingsDivider()
            DSStatusRow("Launch at login") {
                Text("Configured in macOS Login Items")
                    .font(SettingsDesign.rowValue)
                    .foregroundStyle(DS.Color.foregroundTertiary)
            }
            SettingsDivider()
            DSStatusRow("Appearance") {
                Picker("", selection: $model.appearanceTheme) {
                    Text(AppearanceTheme.system.displayName).tag(AppearanceTheme.system)
                    Text(AppearanceTheme.light.displayName).tag(AppearanceTheme.light)
                    Text(AppearanceTheme.dark.displayName).tag(AppearanceTheme.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                Text("Applies to the menu popover")
                    .font(SettingsDesign.rowValue)
                    .foregroundStyle(DS.Color.foregroundTertiary)
            }
        }
    }
}

private struct EngineSection: View {
    @ObservedObject var model: SettingsFormModel

    var body: some View {
        // Codex PM-review UX-10/UX-11/UX-12: don't let users pick a
        // configuration that can't record. Cloud is the only option
        // until local transcription ships; the disabled-but-visible
        // row signals "this is coming" without offering a dead-end.
        SettingsBox(title: "Transcription") {
            // Active engine as a status row: label left, indicator and
            // mono value right, matching the canonical design pattern.
            DSStatusRow("Engine") {
                HStack(spacing: 6) {
                    Indicator(state: .ready, label: "Active")
                    Text("ElevenLabs · cloud")
                        .font(SettingsDesign.rowValue)
                        .foregroundStyle(DS.Color.foregroundSecondary)
                }
            }
            DSStatusRow("ElevenLabs key") {
                SecureField("Paste your ElevenLabs API key", text: $model.apiKey)
                    .textFieldStyle(DSTextFieldStyle())
                    .frame(maxWidth: 340)
            }
            SettingsDivider()
            HStack(alignment: .top, spacing: 18) {
                // Spacer to align with the 160pt label column above.
                Color.clear.frame(width: 160, height: 0)
                Text("Saved securely in Keychain.")
                    .font(SettingsDesign.caption)
                    .foregroundStyle(DS.Color.foregroundTertiary)
                Spacer(minLength: 0)
            }
            SettingsDivider()
            DSStatusRow("Local engine") {
                HStack(spacing: 6) {
                    Indicator(state: .idle, label: "Soon")
                    Text("on-device · coming next")
                        .font(SettingsDesign.rowValue)
                        .foregroundStyle(DS.Color.foregroundTertiary)
                }
            }
        }
    }

    private var keychainServiceLabel: String {
        // Surface the label so users editing keychain via Keychain Access
        // can find the right item.
        Bundle.main.bundleIdentifier ?? "com.szymonsypniewicz.transcriber"
    }
}

private struct AudioSection: View {
    @ObservedObject var model: SettingsFormModel

    var body: some View {
        SettingsBox(title: "Capture") {
            DSStatusRow("System audio") {
                HStack(spacing: 6) {
                    Indicator(state: .ready, label: "Required")
                    Text("Captured through ScreenCaptureKit")
                        .font(SettingsDesign.rowValue)
                        .foregroundStyle(DS.Color.foregroundTertiary)
                }
            }
            SettingsDivider()
            DSStatusRow("Microphone") {
                HStack(spacing: 6) {
                    Indicator(state: .ready, label: "Required")
                    Text("Mixed with call audio for transcription")
                        .font(SettingsDesign.rowValue)
                        .foregroundStyle(DS.Color.foregroundTertiary)
                }
            }
            SettingsDivider()
            DSStatusRow("Keep raw streams") {
                Toggle(isOn: $model.keepRawStreams) { EmptyView() }
                    .toggleStyle(ScribeSwitchStyle())
                    .labelsHidden()
                    .fixedSize()
                Text("Separate mic and call audio · uses more disk")
                    .font(SettingsDesign.rowValue)
                    .foregroundStyle(DS.Color.foregroundTertiary)
            }
        }
    }
}

private struct OutputSection: View {
    @ObservedObject var model: SettingsFormModel

    var body: some View {
        SettingsBox(title: "Location") {
            DSStatusRow("Folder") {
                DSCodeBlock(model.outputRoot.path) {
                    Button("Choose…") { pickFolder() }
                        .buttonStyle(GhostButtonStyle())
                    Button("Reveal") { NSWorkspace.shared.open(model.outputRoot) }
                        .buttonStyle(GhostButtonStyle())
                }
            }
            if model.outputRootIsInICloudDrive || model.outputRootIsInSyncedStorage {
                SettingsDivider()
            }
            // Codex PM-review UX-15: differentiated warning copy for
            // iCloud (passive, sync is fine) vs third-party cloud
            // providers (sync conflicts can corrupt audio). Both are
            // optional; recording works either way.
            if model.outputRootIsInICloudDrive {
                DSStatusRow("Cloud sync") {
                    HStack(spacing: 6) {
                        Indicator(state: .ready, label: "iCloud")
                        Text("Saved sessions sync with iCloud Drive.")
                            .font(SettingsDesign.caption)
                            .foregroundStyle(DS.Color.foregroundTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if model.outputRootIsInSyncedStorage {
                DSStatusRow("Cloud sync") {
                    HStack(alignment: .top, spacing: 8) {
                        Indicator(state: .warning, label: "Synced")
                        Text("Heads up: recordings will upload to your cloud provider as they save. Sync conflicts can create duplicate or incomplete files.")
                            .font(SettingsDesign.caption)
                            .foregroundStyle(DS.Color.foregroundTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
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
            model.refreshStorageUsage()
        }
    }
}

private struct StorageSection: View {
    @ObservedObject var model: SettingsFormModel

    var body: some View {
        SettingsBox(title: "Storage") {
            DSStatusRow("Audio on disk") {
                HStack(spacing: 8) {
                    Text(byteString(model.storageAudioBytes))
                        .font(SettingsDesign.rowValue)
                        .foregroundStyle(DS.Color.foregroundSecondary)
                    Button("Refresh") { model.refreshStorageUsage() }
                        .buttonStyle(GhostButtonStyle())
                }
            }
            SettingsDivider()
            DSStatusRow("Folder") {
                Button("Reveal in Finder") { NSWorkspace.shared.open(model.outputRoot) }
                    .buttonStyle(GhostButtonStyle())
            }
            SettingsDivider()
            DSStatusRow("Delete audio") {
                HStack(spacing: 8) {
                    Button("Delete all audio") { confirmDeleteAudio() }
                        .buttonStyle(GhostButtonStyle())
                        .disabled(model.storageAudioBytes == 0)
                    Text("Keeps transcript.md and metadata.json")
                        .font(SettingsDesign.caption)
                        .foregroundStyle(DS.Color.foregroundTertiary)
                }
            }
            if let error = model.deleteAudioError {
                SettingsDivider()
                DSStatusRow("Storage error") {
                    Text(error)
                        .font(SettingsDesign.caption)
                        .foregroundStyle(DS.Color.danger)
                }
            }
        }
        .onAppear { model.refreshStorageUsage() }
    }

    private func confirmDeleteAudio() {
        let alert = NSAlert()
        alert.messageText = "Delete all Scribe audio?"
        alert.informativeText = "This keeps transcripts and metadata, but removes audio.m4a, mic.m4a, and system.m4a files under the selected Scribe folder."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete audio")
        alert.addButton(withTitle: "Cancel")
        alert.window.sharingType = WindowChromeSharing.confidential
        if alert.runModal() == .alertFirstButtonReturn {
            model.deleteAllAudioKeepingTranscripts()
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct AdvancedSection: View {
    @ObservedObject var model: SettingsFormModel

    var body: some View {
        // Codex PM-review UX-17: AEC toggle was a debugging knob for
        // a feature that doesn't actually ship in rc4 (the backend
        // is a placeholder). Hide until the real AEC pre-pass lands.
        // The setting is preserved on disk; the model.aecEnabled
        // value still threads through the worker.
        EmptyView()
    }
}

private struct PrivacyStatusSection: View {
    @ObservedObject var model: SettingsFormModel

    var body: some View {
        // Codex PM-review UX-32: re-readable privacy details from
        // Settings. The first-launch modal acknowledgement is
        // one-way; this section gives the user the link without
        // pretending they can revoke (which would require disabling
        // cloud-mode recording, a separate feature).
        SettingsBox(title: "Cloud processing") {
            DSStatusRow("Transcription") {
                Text("Audio is sent to ElevenLabs and deleted there after processing.")
                    .font(SettingsDesign.rowValue)
                    .foregroundStyle(DS.Color.foregroundTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsDivider()
            DSStatusRow("Notice") {
                Indicator(
                    state: model.initialSnapshot.privacyAcknowledged ? .sent : .warning,
                    label: model.initialSnapshot.privacyAcknowledged ? "Acked" : "Pending"
                )
                Text(model.initialSnapshot.privacyAcknowledged
                     ? "Acknowledged at first launch"
                     : "Not yet acknowledged")
                    .font(SettingsDesign.rowValue)
                    .foregroundStyle(DS.Color.foregroundTertiary)
            }
            SettingsDivider()
            DSStatusRow("Reference") {
                Button("Read full privacy details") {
                    if let url = URL(string: "https://github.com/Newarr/scribe/blob/main/docs/user/PRIVACY.md") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(DSLinkButtonStyle())
            }
        }
    }
}

private struct PermissionsSection: View {
    @ObservedObject var model: SettingsFormModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsBox(title: "Required") {
                PermissionRow(
                    name: "Microphone",
                    status: model.microphoneStatus,
                    detail: "Captures your voice from the selected mic.",
                    actionTitle: "Open in System Settings",
                    action: { openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }
                )
                SettingsDivider()
                PermissionRow(
                    name: "Screen Recording",
                    status: model.screenRecordingStatus,
                    detail: "Captures system audio for other speakers. No video is recorded.",
                    actionTitle: "Open in System Settings",
                    action: { openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") }
                )
            }
            SettingsBox(title: "Optional") {
                PermissionRow(
                    name: "Calendar",
                    status: model.calendarStatus,
                    detail: "Adds meeting titles and attendee keyterms to transcript context.",
                    actionTitle: "Open in System Settings",
                    action: { openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") }
                )
                SettingsDivider()
                PermissionRow(
                    name: "Notifications",
                    status: model.notificationStatus,
                    detail: "Shows meeting-detected and transcript-ready alerts.",
                    actionTitle: "Open in System Settings",
                    action: { openSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension") }
                )
            }
            Button("Refresh permissions") { model.refreshPermissionStatuses() }
                .buttonStyle(GhostButtonStyle())
        }
    }

    private func openSettings(_ raw: String) {
        if let url = URL(string: raw) {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct PermissionRow: View {
    let name: String
    let status: PermissionStatus
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(SettingsDesign.rowEmphasis)
                        .foregroundStyle(DS.Color.foreground)
                    Text(label)
                        .font(SettingsDesign.caption)
                        .foregroundStyle(color)
                }
                Text(detail)
                    .font(SettingsDesign.caption)
                    .foregroundStyle(DS.Color.foregroundTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(actionTitle, action: action)
                .buttonStyle(DSLinkButtonStyle())
        }
        .padding(.vertical, 7)
    }

    private var label: String {
        switch status {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not asked"
        }
    }

    private var color: SwiftUI.Color {
        switch status {
        case .granted: return DS.Color.success
        case .denied: return DS.Color.warning
        case .notDetermined: return DS.Color.foregroundTertiary
        }
    }
}

private struct AboutSection: View {
    var body: some View {
        SettingsBox(title: "App") {
            DSStatusRow("Version") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development")
                    .font(SettingsDesign.rowValue)
                    .foregroundStyle(DS.Color.foregroundSecondary)
            }
            SettingsDivider()
            DSStatusRow("Build") {
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Debug")
                    .font(SettingsDesign.rowValue)
                    .foregroundStyle(DS.Color.foregroundTertiary)
            }
            SettingsDivider()
            DSStatusRow("Output") {
                Text("Every session ends with transcript.md")
                    .font(SettingsDesign.rowValue)
                    .foregroundStyle(DS.Color.foregroundTertiary)
            }
        }
    }
}
