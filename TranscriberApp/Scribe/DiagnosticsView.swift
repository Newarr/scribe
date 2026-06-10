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
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        host.title = "Diagnostics"
        host.center()
        host.isReleasedWhenClosed = false
        // Codex PM-review UX-4: confidential UI.
        host.sharingType = WindowChromeSharing.confidential
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
        let delegate = CloseCallbackWindowDelegate(onClose: { [weak self] in self?.window = nil })
        host.delegate = delegate
        objc_setAssociatedObject(host, &diagnosticsWindowDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        WindowChrome.installGlass(on: host, material: .hudWindow)
        self.window = host
        host.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
            head
            Divider()
                .background(SwiftUI.Color.white.opacity(0.06))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headerSection
                        .padding(.bottom, 12)
                    settingsSection
                    permissionsSection
                    engineSection
                    sessionsSection
                    if let levels = model.snapshot.liveLevels {
                        liveLevelsSection(levels)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.top, 32)
                .padding(.bottom, 36)
            }
        }
        .frame(minWidth: 540, minHeight: 600)
        .glassBackground()
        .task {
            // Codex P1.3: load real async values on first appear.
            refreshing = true
            await onRefresh()
            refreshing = false
        }
    }

    private var head: some View {
        HStack {
            Text("Diagnostics")
                .font(DS.Font.subheading)
                .foregroundStyle(DS.Color.foreground)
            Spacer()
            if let url = model.lastExportPath {
                HStack(spacing: 7) {
                    Indicator(state: .sent, label: "Saved")
                    Text(url.lastPathComponent)
                        .font(DS.Font.monoSmall)
                        .foregroundStyle(DS.Color.foregroundSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.trailing, 6)
            }
            if let err = model.exportError {
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
            Button(refreshing ? "Refreshing…" : "Refresh") {
                Task {
                    refreshing = true
                    await onRefresh()
                    refreshing = false
                }
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(exporting || refreshing)
            Button(exporting ? "Exporting…" : "Export…") {
                Task { await runExport() }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(PrimaryButtonStyle())
            .hoverSheen()
            .disabled(exporting || refreshing)
        }
        .padding(.horizontal, 18)
        .frame(height: 38)
    }

    private var headerSection: some View {
        // scribe-design-system: panel-h1 + panel-sub. Brand wordmark
        // sits above the title so the diagnostics window still feels
        // like a Scribe surface.
        VStack(alignment: .leading, spacing: 12) {
            BrandWordmark(height: 24)
                .foregroundStyle(DS.Color.foreground)
            VStack(alignment: .leading, spacing: 6) {
                Text("Diagnostics")
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.foreground)
                Text("Snapshot of your environment, permissions, and session history. Export pulls a redacted JSON file we can ship to support.")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.foregroundSecondary)
                    .lineSpacing(2)
                    .frame(maxWidth: 540, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("v\(model.snapshot.appVersion) · macOS \(model.snapshot.osVersion.major).\(model.snapshot.osVersion.minor).\(model.snapshot.osVersion.patch) · \(model.snapshot.exportedAt)")
                .font(DS.Font.eyebrow)
                .tracking(0.44)
                .foregroundStyle(DS.Color.foregroundTertiary)
        }
    }

    // Codex PM-review UX-27: show the actual output path here, not
    // the HMAC hash. The hash is for the EXPORTED diagnostics blob;
    // an in-app diagnostics view should help the user, who knows
    // where their files live.
    private var settingsSection: some View {
        DSSection("Settings") {
            row("Transcription", model.snapshot.settings.engineMode == "cloud" ? "ElevenLabs (Cloud)" : "Local")
            boolRow("Output folder writable", model.snapshot.settings.outputRootIsWritable)
            DSStatusRow("Folder fingerprint") {
                DSCodeBlock(String(model.snapshot.settings.outputRootHash.prefix(12)) + "…")
            }
            boolRow("Privacy notice acknowledged", model.snapshot.settings.privacyAcknowledged)
            boolRow("Keep separate mic and call audio", model.snapshot.settings.keepRawStreams)
        }
    }

    private var permissionsSection: some View {
        DSSection("Permissions") {
            permissionRow("Microphone", model.snapshot.permissions.microphone)
            permissionRow("Screen & System Audio Recording", model.snapshot.permissions.screenRecording)
            permissionRow("Calendar (optional)", model.snapshot.permissions.calendar)
            row("Active calendar source", calendarSourceLabel(model.snapshot.activeCalendarSource))
        }
    }

    // Codex PM-review UX-28: user-readable diagnostic labels.
    // "Engine readiness" was support jargon.
    private var engineSection: some View {
        DSSection("Transcription") {
            row("Selected engine", model.snapshot.engine.selectedEngine)
            boolRow("Selected engine ready", model.snapshot.engine.selectedEngineReady)
            row("ElevenLabs key", model.snapshot.engine.cloudKey)
            row("Local model status", model.snapshot.engine.localModelStatus)
            row("Local model", model.snapshot.engine.localModelID)
            boolRow("Local cache present", model.snapshot.engine.localCachePathExists)
            boolRow("Local MLX runtime", model.snapshot.engine.mlxAvailable)
            boolRow("Cohere local ready", model.snapshot.engine.localReady)
            if model.snapshot.engine.lastDownloadError.isEmpty == false {
                row("Last local setup error", model.snapshot.engine.lastDownloadError)
            }
        }
    }

    private var sessionsSection: some View {
        DSSection("Recent sessions") {
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
            row("ElevenLabs sessions", "\(model.snapshot.sessions.cloudEngineSessions)")
            row("Cohere sessions", "\(model.snapshot.sessions.localEngineSessions)")
            if model.snapshot.sessions.unknownEngineSessions > 0 {
                row("Unknown engine sessions", "\(model.snapshot.sessions.unknownEngineSessions)")
            }
            row("Total retries", "\(model.snapshot.sessions.totalRetries)")
        }
    }

    // Codex PM-review UX-28: "Live RMS levels" -> "Audio levels".
    private func liveLevelsSection(_ levels: DiagnosticsSnapshot.LiveLevels) -> some View {
        DSSection("Audio levels") {
            if let mic = levels.micRMS {
                DiagnosticsLevelBar(label: "Microphone", value: mic)
            }
            if let sys = levels.systemRMS {
                DiagnosticsLevelBar(label: "Call audio", value: sys)
            }
        }
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
        DSStatusRow(label) {
            if monospaced {
                Text(value)
                    .font(DS.Font.monoBody)
                    .foregroundStyle(DS.Color.foreground)
            } else {
                Text(value)
                    .font(DS.Font.monoBody)
                    .foregroundStyle(DS.Color.foregroundSecondary)
            }
        }
    }

    /// Bool values render as label + indicator via the canonical
    /// `DSStatusRow` pattern. Matches the design references where
    /// every settings/diagnostics value uses this label-on-left,
    /// status-on-right rhythm.
    private func boolRow(_ label: String, _ on: Bool) -> some View {
        DSStatusRow(label) {
            Indicator(state: on ? .sent : .idle, label: on ? "On" : "Off")
        }
    }

    private func permissionRow(_ label: String, _ status: String) -> some View {
        DSStatusRow(label) {
            // scribe-design-system: replace the filled SF Symbol pill
            // with the design's `.indicator` primitive (dot + uppercase
            // mono label). Status remains semantically encoded; the
            // rendering stops looking like a Mac System Settings clone.
            Indicator(state: indicatorState(for: status), label: indicatorLabel(for: status))
        }
    }

    private func calendarSourceLabel(_ source: String) -> String {
        switch source {
        case "appleCalendar": return "Apple Calendar"
        case "none": return "None"
        default: return "Unknown"
        }
    }

    private func indicatorState(for status: String) -> Indicator.State {
        switch status {
        case "granted":              return .sent
        case "denied", "restricted": return .failed
        default:                     return .warning
        }
    }

    private func indicatorLabel(for status: String) -> String {
        switch status {
        case "granted":              return "Granted"
        case "denied":               return "Denied"
        case "restricted":           return "Restricted"
        case "notDetermined":        return "Not asked"
        default:                     return status
        }
    }
}

/// Diagnostics-specific level bar. Mirrors the popover `LevelBar` shape
/// (Capsule track, hairline fill, mono caption) so the chrome reads as
/// the same primitive across windows.
private struct DiagnosticsLevelBar: View {
    let label: String
    let value: Double

    var body: some View {
        DSStatusRow(label) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(SwiftUI.Color.white.opacity(0.04))
                        .frame(height: 4)
                    Capsule()
                        .fill(DS.Color.success)
                        .frame(width: geo.size.width * CGFloat(min(max(value, 0), 1)), height: 4)
                }
            }
            .frame(maxWidth: 240, maxHeight: 4, alignment: .leading)
            Text(String(format: "%.2f", value))
                .font(DS.Font.monoBody)
                .foregroundStyle(DS.Color.foregroundTertiary)
                .frame(width: 56, alignment: .trailing)
        }
    }
}
