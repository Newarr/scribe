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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        host.title = "Transcriber Settings"
        host.center()
        host.isReleasedWhenClosed = false
        // Codex PM-review UX-4: confidential UI.
        host.sharingType = .none
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
/// blob) — the form reads + writes it directly so the Save button
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
        // Third-party cloud providers — sync conflicts can corrupt
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
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    EngineSection(model: model)
                    OutputSection(model: model)
                    AdvancedSection(model: model)
                    PrivacyStatusSection(model: model)
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 600)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let err = model.saveError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 12))
            }
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .disabled(saving)
            Button(saving ? "Saving…" : "Save") {
                Task { await save() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(saving)
        }
        .padding(16)
    }

    @MainActor
    private func save() async {
        saving = true
        defer { saving = false }
        model.saveError = nil
        // Codex Phase η P1.2: keychain write THEN settings commit, both
        // awaited. If keychain fails, surface and abort. If settings
        // commit fails, the keychain key was already written — log the
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
        SectionHeader("Transcription") {
            VStack(alignment: .leading, spacing: 6) {
                Text("ElevenLabs (Cloud)").bold()
                Text("Recordings are sent to ElevenLabs for transcription.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("ElevenLabs key").font(.system(size: 12))
                SecureField("Paste your ElevenLabs API key", text: $model.apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Saved securely in Keychain.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 4)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "clock.badge")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local transcription — coming later").bold()
                    Text("Future versions will run transcription on your Mac without sending audio anywhere.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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
        SectionHeader("Where transcripts are saved") {
            HStack {
                Text(model.outputRoot.path)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose folder…") { pickFolder() }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.open(model.outputRoot)
                }
                .controlSize(.small)
            }
            // Codex PM-review UX-15: differentiated warning copy for
            // iCloud (passive, sync is fine) vs third-party cloud
            // providers (sync conflicts can corrupt audio). Both are
            // optional — recording works either way.
            if model.outputRootIsInICloudDrive {
                Label {
                    Text("Saved sessions sync with iCloud Drive.")
                        .font(.system(size: 11))
                } icon: {
                    Image(systemName: "icloud")
                        .foregroundStyle(.secondary)
                }
            } else if model.outputRootIsInSyncedStorage {
                Label {
                    Text("Heads up: recordings will upload to your cloud provider as they save. Sync conflicts can create duplicate or incomplete files.")
                        .font(.system(size: 11))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
            }
            // Codex PM-review UX-16: rename + plain-language helper.
            // The user doesn't know what "raw streams" mean.
            Toggle(isOn: $model.keepRawStreams) {
                VStack(alignment: .leading) {
                    Text("Keep separate mic and call audio files")
                    Text("Use this if support asks, or if you want to reprocess speaker separation later. Uses more disk space.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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
        // cloud-mode recording — a separate feature).
        SectionHeader("Privacy") {
            HStack {
                Image(systemName: model.initialSnapshot.privacyAcknowledged ? "checkmark.seal.fill" : "questionmark.seal.fill")
                    .foregroundStyle(model.initialSnapshot.privacyAcknowledged ? .green : .orange)
                Text(model.initialSnapshot.privacyAcknowledged
                     ? "Privacy notice acknowledged"
                     : "Privacy notice not yet acknowledged")
            }
            Text("Recordings are sent to ElevenLabs for transcription. Calendar event titles and attendees may be sent as transcription hints if Calendar is granted.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Read full privacy details") {
                if let url = URL(string: "https://github.com/Newarr/transcriber/blob/main/docs/PRIVACY.md") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
        }
    }
}

private struct SectionHeader<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
    }
}
