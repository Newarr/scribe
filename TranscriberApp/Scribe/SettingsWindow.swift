import AppKit
import SwiftUI
import TranscriberCore

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
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        host.title = "Scribe Settings"
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
    @Published var keepRawStreams: Bool
    @Published var aecEnabled: Bool
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
    @State private var saving: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Reference `.main-head`: 38pt header bar, 13/600 title left,
            // Discard / Save right, hairline divider below. Carries the
            // window's primary actions so the body scrolls without
            // pinned chrome.
            head
            Divider()
                .background(SwiftUI.Color.white.opacity(0.06))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Reference `.panel-h1` + `.panel-sub` open the body
                    // before the first `.sec`.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Settings")
                            .font(DS.Font.title)
                            .foregroundStyle(DS.Color.foreground)
                        Text("Tune the engine, where files land, and how Scribe shows up while it captures.")
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Color.foregroundSecondary)
                            .lineSpacing(2)
                            .frame(maxWidth: 540, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 12)

                    EngineSection(model: model)
                    OutputSection(model: model)
                    AdvancedSection(model: model)
                    PrivacyStatusSection(model: model)
                }
                .padding(.horizontal, 36)
                .padding(.top, 32)
                .padding(.bottom, 36)
            }
        }
        .frame(minWidth: 540, minHeight: 600)
        .glassBackground()
    }

    private var head: some View {
        HStack {
            Text("Settings")
                .font(DS.Font.subheading)
                .foregroundStyle(DS.Color.foreground)
            Spacer()
            if let err = model.saveError {
                HStack(spacing: 7) {
                    Indicator(state: .failed, label: "Error")
                    Text(err)
                        .font(DS.Font.caption)
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
            .disabled(saving)
        }
        .padding(.horizontal, 18)
        .frame(height: 38)
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

private struct EngineSection: View {
    @ObservedObject var model: SettingsFormModel

    var body: some View {
        // Codex PM-review UX-10/UX-11/UX-12: don't let users pick a
        // configuration that can't record. Cloud is the only option
        // until local transcription ships; the disabled-but-visible
        // row signals "this is coming" without offering a dead-end.
        DSSection(
            "Transcription",
            help: "Each meeting's audio is sent to ElevenLabs for transcription. The audio is deleted there after processing."
        ) {
            // Active engine as a status row: label left, indicator and
            // mono value right, matching the canonical design pattern.
            DSStatusRow("Engine") {
                HStack(spacing: 6) {
                    Indicator(state: .ready, label: "Active")
                    Text("ElevenLabs · cloud")
                        .font(DS.Font.monoBody)
                        .foregroundStyle(DS.Color.foregroundSecondary)
                }
            }
            DSStatusRow("ElevenLabs key") {
                SecureField("Paste your ElevenLabs API key", text: $model.apiKey)
                    .textFieldStyle(DSTextFieldStyle())
                    .frame(maxWidth: 340)
            }
            HStack(alignment: .top, spacing: 18) {
                // Spacer to align with the 160pt label column above.
                Color.clear.frame(width: 160, height: 0)
                Text("Saved securely in Keychain.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.foregroundTertiary)
                Spacer(minLength: 0)
            }
            DSStatusRow("Local engine") {
                HStack(spacing: 6) {
                    Indicator(state: .idle, label: "Soon")
                    Text("on-device · coming next")
                        .font(DS.Font.monoBody)
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

private struct OutputSection: View {
    @ObservedObject var model: SettingsFormModel

    var body: some View {
        DSSection(
            "Where transcripts are saved",
            help: "Pick a folder on your Mac. Each session writes a Markdown transcript with frontmatter alongside its audio."
        ) {
            DSStatusRow("Folder") {
                DSCodeBlock(model.outputRoot.path) {
                    Button("Choose…") { pickFolder() }
                        .buttonStyle(GhostButtonStyle())
                    Button("Reveal") { NSWorkspace.shared.open(model.outputRoot) }
                        .buttonStyle(GhostButtonStyle())
                }
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
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.foregroundTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if model.outputRootIsInSyncedStorage {
                DSStatusRow("Cloud sync") {
                    HStack(alignment: .top, spacing: 8) {
                        Indicator(state: .warning, label: "Synced")
                        Text("Heads up: recordings will upload to your cloud provider as they save. Sync conflicts can create duplicate or incomplete files.")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.foregroundTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            // Codex PM-review UX-16: rename + plain-language helper.
            // The user doesn't know what "raw streams" mean.
            DSStatusRow("Keep raw streams") {
                Toggle(isOn: $model.keepRawStreams) { EmptyView() }
                    .toggleStyle(ScribeSwitchStyle())
                    .labelsHidden()
                    .fixedSize()
                Text("Separate mic and call audio · uses more disk")
                    .font(DS.Font.monoBody)
                    .foregroundStyle(DS.Color.foregroundTertiary)
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
        }
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
        DSSection(
            "Privacy",
            help: "Recordings are sent to ElevenLabs for transcription. Calendar event titles and attendees may be sent as transcription hints if Calendar is granted."
        ) {
            DSStatusRow("Notice") {
                Indicator(
                    state: model.initialSnapshot.privacyAcknowledged ? .sent : .warning,
                    label: model.initialSnapshot.privacyAcknowledged ? "Acked" : "Pending"
                )
                Text(model.initialSnapshot.privacyAcknowledged
                     ? "Acknowledged at first launch"
                     : "Not yet acknowledged")
                    .font(DS.Font.monoBody)
                    .foregroundStyle(DS.Color.foregroundTertiary)
            }
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
