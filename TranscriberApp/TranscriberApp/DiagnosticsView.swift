import AppKit
import SwiftUI
import TranscriberCore

/// Phase θ Diagnostics window. Spec line 364 wants live levels, key
/// validity, local model status, output writability, and recent session
/// statuses **displayed**, not just exported. This is the in-app
/// surface; AppDelegate's "Export Diagnostics…" menu item produces the
/// JSON file.
@MainActor
final class DiagnosticsWindowController {
    private let snapshotProvider: @MainActor () async -> DiagnosticsSnapshot
    private let exportHandler: @MainActor () async -> URL?
    private var window: NSWindow?

    init(
        snapshotProvider: @escaping @MainActor () async -> DiagnosticsSnapshot,
        exportHandler: @escaping @MainActor () async -> URL?
    ) {
        self.snapshotProvider = snapshotProvider
        self.exportHandler = exportHandler
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Codex Phase θ P1.3: permission probes are async; show window
        // immediately with a placeholder snapshot, then refresh.
        let model = DiagnosticsViewModel(initial: AppDelegate.emptyDiagnosticsSnapshot())
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        host.title = "Diagnostics"
        host.center()
        host.isReleasedWhenClosed = false
        host.contentView = NSHostingView(rootView: DiagnosticsView(
            model: model,
            onRefresh: { [weak self] in
                guard let self else { return }
                model.snapshot = await self.snapshotProvider()
            },
            onExport: { [weak self] in
                guard let self else { return nil }
                return await self.exportHandler()
            }
        ))
        let delegate = DiagnosticsWindowDelegate { [weak self] in self?.window = nil }
        host.delegate = delegate
        objc_setAssociatedObject(host, &diagnosticsWindowDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        self.window = host
        host.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class DiagnosticsWindowDelegate: NSObject, NSWindowDelegate, @unchecked Sendable {
    private let onClose: @MainActor () -> Void
    init(onClose: @escaping @MainActor () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in onClose() }
    }
}

nonisolated(unsafe) private var diagnosticsWindowDelegateKey: UInt8 = 0

@MainActor
final class DiagnosticsViewModel: ObservableObject {
    @Published var snapshot: DiagnosticsSnapshot
    @Published var lastExportPath: URL?
    @Published var exportError: String?

    init(initial: DiagnosticsSnapshot) {
        self.snapshot = initial
    }
}

private struct DiagnosticsView: View {
    @ObservedObject var model: DiagnosticsViewModel
    let onRefresh: @MainActor () async -> Void
    let onExport: @MainActor () async -> URL?
    @State private var exporting = false
    @State private var refreshing = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    settingsSection
                    permissionsSection
                    engineSection
                    sessionsSection
                    if let levels = model.snapshot.liveLevels {
                        liveLevelsSection(levels)
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 540, minHeight: 600)
        .task {
            // Codex P1.3: load real async values on first appear.
            refreshing = true
            await onRefresh()
            refreshing = false
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Transcriber").font(.title3).fontWeight(.semibold)
            HStack(spacing: 12) {
                Label(model.snapshot.appVersion, systemImage: "tag")
                Label(model.snapshot.exportedAt, systemImage: "clock")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private var settingsSection: some View {
        SectionCard(title: "Settings") {
            row("Engine", model.snapshot.settings.engineMode)
            row("Output writable", boolText(model.snapshot.settings.outputRootIsWritable))
            row("Output root", String(model.snapshot.settings.outputRootHash.prefix(12)) + "…", monospaced: true)
            row("Privacy acknowledged", boolText(model.snapshot.settings.privacyAcknowledged))
            row("Keep raw streams", boolText(model.snapshot.settings.keepRawStreams))
            row("AEC enabled", boolText(model.snapshot.settings.aecEnabled))
        }
    }

    private var permissionsSection: some View {
        SectionCard(title: "Permissions") {
            permissionRow("Microphone", model.snapshot.permissions.microphone)
            permissionRow("Screen & System Audio Recording", model.snapshot.permissions.screenRecording)
            permissionRow("Calendar (optional)", model.snapshot.permissions.calendar)
        }
    }

    private var engineSection: some View {
        SectionCard(title: "Engine readiness") {
            row("Cloud API key", model.snapshot.engine.cloudKey)
            if let p = model.snapshot.engine.localBinaryPresent {
                row("Local engine binary", boolText(p))
            }
            if let p = model.snapshot.engine.localLanguageModelPresent {
                row("Language detection model", boolText(p))
            }
        }
    }

    private var sessionsSection: some View {
        SectionCard(title: "Recent sessions") {
            row("Total", "\(model.snapshot.sessions.total)")
            row("Pending", "\(model.snapshot.sessions.pending)")
            row("Retrying", "\(model.snapshot.sessions.retrying)")
            row("Complete", "\(model.snapshot.sessions.complete)")
            row("Failed", "\(model.snapshot.sessions.failed)")
            if model.snapshot.sessions.unknown > 0 {
                row("Unknown / corrupt", "\(model.snapshot.sessions.unknown)")
            }
            if model.snapshot.sessions.orphanedWithAudio > 0 {
                row("Orphaned (audio, no transcript)", "\(model.snapshot.sessions.orphanedWithAudio)")
            }
            row("Total retries", "\(model.snapshot.sessions.totalRetries)")
        }
    }

    private func liveLevelsSection(_ levels: DiagnosticsSnapshot.LiveLevels) -> some View {
        SectionCard(title: "Live RMS levels") {
            if let mic = levels.micRMS {
                LevelBar(label: "Mic", value: mic)
            }
            if let sys = levels.systemRMS {
                LevelBar(label: "System", value: sys)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let url = model.lastExportPath {
                Label("Saved to \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let err = model.exportError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 11))
            }
            Spacer()
            Button(refreshing ? "Refreshing…" : "Refresh") {
                Task {
                    refreshing = true
                    await onRefresh()
                    refreshing = false
                }
            }
            .disabled(exporting || refreshing)
            Button(exporting ? "Exporting…" : "Export…") {
                Task { await runExport() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(exporting || refreshing)
        }
        .padding(16)
    }

    @MainActor
    private func runExport() async {
        exporting = true
        defer { exporting = false }
        model.exportError = nil
        if let url = await onExport() {
            model.lastExportPath = url
        } else {
            model.exportError = "Export failed; see Console for details."
        }
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            if monospaced {
                Text(value).font(.system(.body, design: .monospaced))
            } else {
                Text(value)
            }
        }
    }

    private func permissionRow(_ label: String, _ status: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Label(status, systemImage: iconFor(status))
                .foregroundStyle(colorFor(status))
                .font(.system(size: 12))
        }
    }

    private func boolText(_ b: Bool) -> String { b ? "Yes" : "No" }

    private func iconFor(_ status: String) -> String {
        switch status {
        case "granted": return "checkmark.circle.fill"
        case "denied", "restricted": return "xmark.octagon.fill"
        default: return "questionmark.circle.fill"
        }
    }

    private func colorFor(_ status: String) -> Color {
        switch status {
        case "granted": return .green
        case "denied", "restricted": return .red
        default: return .orange
        }
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(12)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)
        }
    }
}

private struct LevelBar: View {
    let label: String
    let value: Double

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            ProgressView(value: min(max(value, 0), 1))
                .progressViewStyle(.linear)
            Text(String(format: "%.2f", value))
                .font(.system(.body, design: .monospaced))
                .frame(width: 60, alignment: .trailing)
        }
    }
}
