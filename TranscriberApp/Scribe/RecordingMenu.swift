import AppKit
import SwiftUI
import TranscriberCore

/// F-6: scribe-design-system custom popover replacing the previous
/// `NSMenu`. The popover anchors to the menu-bar status item and
/// presents one of two layouts based on the live `SessionStatus`:
///
///   - **Idle / last:** header with brand mark + state badge, body
///     with up to five recent sessions (each with title, duration,
///     relative time, and inline open-folder / open-transcript / retry
///     actions), footer with Settings / Diagnostics / Quit.
///   - **Recording:** header with brand mark + `REC · 04:21` indicator,
///     body with the live source label + elapsed time + waveform plus
///     a CAPTURING group of System audio / Mic status rows; footer
///     with `Stop and save` primary + `Open folder` ghost.
///
/// The previous `NSMenu`-driven API (a `RecordingMenu` exposing
/// `menu: NSMenu` and an `Action` enum) is preserved as the public
/// surface so AppDelegate's call sites don't change. The popover hosts
/// a SwiftUI body backed by `RecordingMenuModel`.
@MainActor
final class RecordingMenu: NSObject, NSPopoverDelegate {
    enum Action {
        case record, stop, quit, openSettings, openSetupRequired, openDiagnostics
    }

    /// Codex PM-review UX-7 (preserved): "Setup Required…" vs
    /// "Check setup…". AppDelegate flips this; the popover header
    /// now folds it into a single SETUP indicator.
    var setupNeedsAttention: Bool = false {
        didSet { model.setupNeedsAttention = setupNeedsAttention }
    }

    /// `outputRoot` powers the recents enumerator. Updated by
    /// AppDelegate before each popover open so the list reflects
    /// any settings change.
    var outputRoot: URL? {
        didSet { model.refreshRecents(under: outputRoot) }
    }

    /// Elapsed seconds since recording started. AppDelegate ticks
    /// this once per second from a `Timer` while in the recording
    /// state so the popover header + capture card show a live timer
    /// instead of a frozen `0:00`. The popover uses
    /// `font: monospaced digit` so per-tick width changes don't
    /// jitter the surface.
    var elapsedSeconds: Int = 0 {
        didSet { model.elapsedSeconds = elapsedSeconds }
    }

    /// Right-side label inside the live indicator on the recording
    /// surface. AppDelegate sets this to the matched calendar event
    /// title (preferred), the detection candidate's display name,
    /// or `Recording` when neither is known.
    var recordingSourceLabel: String = "Recording" {
        didSet { model.recordingSourceLabel = recordingSourceLabel }
    }

    /// Where the saved transcript will land. AppDelegate sets this
    /// when a session starts so the recording surface's outcome
    /// strip can show the user the destination folder name. Nil
    /// hides the strip.
    var outcomeFolderName: String? {
        didSet { model.outcomeFolderName = outcomeFolderName }
    }

    var outcomeFolderURL: URL? {
        didSet { model.outcomeFolderURL = outcomeFolderURL }
    }

    var appearanceTheme: AppearanceTheme = .system {
        didSet { model.appearanceTheme = appearanceTheme }
    }

    let popover: NSPopover
    private let onAction: (Action) -> Void
    private let model: RecordingMenuModel
    private weak var anchorButton: NSStatusBarButton?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?

    init(onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
        let model = RecordingMenuModel(status: .idle)
        self.model = model
        let popover = NSPopover()
        self.popover = popover
        super.init()
        model.appearanceTheme = appearanceTheme
        popover.delegate = self
        popover.behavior = .transient
        // Size driven by the SwiftUI body's `.frame(width:)` +
        // `.fixedSize(horizontal: false, vertical: true)`. Leaving
        // `contentSize` unset lets NSPopover read NSHostingController's
        // intrinsic content size; empty state gets ~190pt, full
        // recents list scales up.
        // NSPopover already provides system vibrancy chrome; the
        // SwiftUI body uses `.glassBackground()` (Color.clear + the
        // 1px specular highlight) so the chrome shows through without
        // a manual NSVisualEffectView wrapper. An earlier attempt to
        // call `WindowChrome.wrapInGlass(controller:)` here broke the
        // popover layout because reassigning `NSHostingController.view`
        // disables its intrinsic SwiftUI sizing; the popover would
        // then refuse to present.
        let host = NSHostingController(rootView: RecordingPopoverContent(
            model: model,
            onAction: onAction
        ))
        popover.contentViewController = host
        rebuild(for: .idle)
    }

    deinit {
        MainActor.assumeIsolated {
            removeOutsideClickMonitors()
        }
    }

    /// Status update hook (preserves the old API).
    func rebuild(for status: SessionStatus) {
        model.status = status
        applyDebugMenuFixtureIfNeeded()
    }

    /// Presents the popover anchored to `button`. AppDelegate calls
    /// this in response to the status-item button click; the previous
    /// `NSStatusItem.menu` auto-presentation no longer applies.
    func show(from button: NSStatusBarButton) {
        if popover.isShown {
            close()
            return
        }
        // Refresh recents on each open. NSPopover caches the host
        // view so this stays cheap; the enumerator only touches
        // frontmatter, never bodies.
        model.refreshRecents(under: outputRoot)
        applyDebugMenuFixtureIfNeeded()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Codex UX-4: confidential UI. NSPopover hosts a backing
        // window; opt it out of screen-share captures.
        popover.contentViewController?.view.window?.sharingType = WindowChromeSharing.confidential
        anchorButton = button
        installOutsideClickMonitors()
    }

    func close() {
        popover.performClose(nil)
        removeOutsideClickMonitors()
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.removeOutsideClickMonitors()
        }
    }

    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            MainActor.assumeIsolated {
                self?.closeIfClickIsOutsidePopover(event)
            }
            return event
        }
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.close()
            }
        }
    }

    private func removeOutsideClickMonitors() {
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
    }

    private func closeIfClickIsOutsidePopover(_ event: NSEvent) {
        guard popover.isShown else {
            removeOutsideClickMonitors()
            return
        }
        if event.window === popover.contentViewController?.view.window {
            return
        }
        if let button = anchorButton,
           event.window === button.window,
           button.bounds.contains(button.convert(event.locationInWindow, from: nil)) {
            return
        }
        close()
    }

    private func applyDebugMenuFixtureIfNeeded() {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["SCRIBE_DEBUG_MENU_STATE"]?.lowercased() else { return }
        switch raw {
        case "idle":
            model.status = .idle
        case "recording":
            model.status = .recording
            model.elapsedSeconds = max(model.elapsedSeconds, 76)
            model.recordingSourceLabel = model.recordingSourceLabel == "Recording" ? "Zoom · Design review" : model.recordingSourceLabel
            model.outcomeFolderName = model.outcomeFolderName ?? "2026-05-07 09:41 - Design review"
        case "failed":
            model.status = .failed
        default:
            break
        }
        #endif
    }
}

@MainActor
final class RecordingMenuModel: ObservableObject {
    @Published var status: SessionStatus
    @Published var setupNeedsAttention: Bool = false
    @Published var recents: [SessionFolderEnumerator.Entry] = []
    @Published var elapsedSeconds: Int = 0
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    /// Right-aligned status text inside the live indicator on the
    /// recording surface. Pattern: `"Zoom · Acme Q3 sync"` when source
    /// and meeting title are both known; falls back to `"Recording"`.
    @Published var recordingSourceLabel: String = "Recording"
    /// Right-side mono value for the System audio row in the
    /// CAPTURING group. Pattern: `"on · 48 kHz"` / `"off"`.
    @Published var systemAudioLabel: String = "on · 48 kHz"
    /// Right-side mono value for the Mic row. Defaults to the system
    /// default device's display name when known; falls back to `"-"`.
    @Published var micLabel: String = "-"
    /// Where the saved transcript will land (folder name only, e.g.
    /// `2026-04-30 14:02 - Acme Q3 sync`). Nil hides the outcome
    /// strip below the waveform.
    @Published var outcomeFolderName: String? = nil
    @Published var outcomeFolderURL: URL? = nil
    @Published var appearanceTheme: AppearanceTheme = .system

    init(status: SessionStatus) {
        self.status = status
    }

    func refreshRecents(under root: URL?) {
        guard let root else { recents = []; return }
        recents = SessionFolderEnumerator.recents(under: root, limit: 5)
    }
}

private struct RecordingPopoverContent: View {
    @ObservedObject var model: RecordingMenuModel
    let onAction: (RecordingMenu.Action) -> Void

    private let menuWidth: CGFloat = 420
    @SwiftUI.State private var didAppear: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = RecordingPopoverPalette(colorScheme: colorScheme)
        VStack(spacing: 0) {
            header(palette: palette)
            Rectangle()
                .fill(palette.line)
                .frame(height: 1)
            content(palette: palette)
        }
        .background(palette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.line, lineWidth: 1)
        )
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [SwiftUI.Color.clear, palette.specular, SwiftUI.Color.clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
            .padding(.horizontal, 18)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: palette.shadow, radius: 18, x: 0, y: 8)
        .frame(width: menuWidth)
        .fixedSize(horizontal: false, vertical: true)
        .opacity(didAppear ? 1 : 0)
        .offset(y: didAppear ? 0 : -6)
        .animation(.easeOut(duration: 0.18), value: didAppear)
        .onAppear { didAppear = true }
        .preferredColorScheme(model.appearanceTheme.preferredColorScheme)
    }

    private func header(palette: RecordingPopoverPalette) -> some View {
        HStack(spacing: 12) {
            BrandMark(size: 14)
                .foregroundStyle(palette.text)
            Text("scribe")
                .font(DS.Font.subheading)
                .foregroundStyle(palette.text)
            Spacer()
            StatusBadge(
                text: headerStatusText,
                color: headerStatusColor(palette: palette)
            )
            Button {
                onAction(.openSettings)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(IconButtonStyle(palette: palette))
            .help("Open Settings")
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    @ViewBuilder
    private func content(palette: RecordingPopoverPalette) -> some View {
        switch model.status {
        case .recording, .stopping, .starting, .finalized:
            recordingLayout(palette: palette)
        case .failed:
            failedLayout(palette: palette)
        case .idle:
            idleLayout(palette: palette)
        }
    }

    private func idleLayout(palette: RecordingPopoverPalette) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(model.setupNeedsAttention ? palette.warning : palette.ready)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.setupNeedsAttention ? "Setup needs attention" : "Ready when you are.")
                        .font(DS.Font.heading)
                        .foregroundStyle(palette.text)
                    Text(model.setupNeedsAttention ? "Open setup to grant missing permissions." : "Scribe is watching for calls. Start manually any time.")
                        .font(DS.Font.bodySmall)
                        .foregroundStyle(palette.secondaryText)
                }
                Spacer()
            }
            if model.recents.isEmpty {
                EmptyView()
            } else {
                VStack(spacing: 1) {
                    ForEach(model.recents, id: \.directory) { entry in
                        MenuRow(entry: entry)
                    }
                }
                .padding(6)
                .background(palette.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(palette.line, lineWidth: 1)
                )
            }
            HStack {
                if model.setupNeedsAttention {
                    Button("Check setup") { onAction(.openSetupRequired) }
                        .buttonStyle(GhostPopoverButtonStyle(palette: palette))
                }
                Spacer()
                Button("Record now") { onAction(.record) }
                    .keyboardShortcut("r", modifiers: [.command])
                    .buttonStyle(PrimaryPopoverButtonStyle(palette: palette))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private func recordingLayout(palette: RecordingPopoverPalette) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(palette.live).frame(width: 8, height: 8)
                Text(model.recordingSourceLabel)
                    .font(DS.Font.heading)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text(timeString(model.elapsedSeconds))
                    .font(SwiftUI.Font.custom(DS.monoFamily, size: 19).weight(.regular))
                    .foregroundStyle(palette.text)
                    .monospacedDigit()
            }
            AnimatedWaveform(palette: palette)
                .frame(height: 148)
            Text("Recording locally · saved when you stop")
                .font(DS.Font.body)
                .foregroundStyle(palette.secondaryText)
            if let folder = model.outcomeFolderName {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .medium))
                    Text(folder)
                        .font(DS.Font.monoSmall)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(palette.tertiaryText)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(palette.controlFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(palette.line, lineWidth: 1)
                )
            }
            HStack {
                Spacer()
                Button("Stop") { onAction(.stop) }
                    .keyboardShortcut("s", modifiers: [.command])
                    .buttonStyle(SecondaryPopoverButtonStyle(palette: palette))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private func failedLayout(palette: RecordingPopoverPalette) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(palette.warning)
                Text("Transcription failed")
                    .font(DS.Font.heading)
                    .foregroundStyle(palette.text)
            }
            Text("Transcription failed, but the recording remains on disk and can be retried.")
                .font(DS.Font.bodySmall)
                .foregroundStyle(palette.secondaryText)
            HStack {
                Spacer()
                Button("Retry") { onAction(.record) }
                    .buttonStyle(PrimaryPopoverButtonStyle(palette: palette))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
    }

    private var headerStatusText: String {
        switch model.status {
        case .recording, .stopping: return "LIVE"
        case .starting: return "STARTING"
        case .finalized: return "SAVING"
        case .failed: return "FAILED"
        case .idle: return model.setupNeedsAttention ? "SETUP" : "READY"
        }
    }

    private func headerStatusColor(palette: RecordingPopoverPalette) -> SwiftUI.Color {
        switch model.status {
        case .recording, .stopping: return palette.live
        case .failed: return palette.warning
        case .idle: return model.setupNeedsAttention ? palette.warning : palette.ready
        default: return palette.secondaryText
        }
    }

    private func timeString(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

private struct RecordingPopoverPalette {
    let colorScheme: ColorScheme

    var surface: SwiftUI.Color {
        colorScheme == .dark
            ? SwiftUI.Color(red: 0.10, green: 0.10, blue: 0.12).opacity(0.86)
            : SwiftUI.Color(red: 0.965, green: 0.956, blue: 0.946).opacity(0.94)
    }

    var controlFill: SwiftUI.Color {
        colorScheme == .dark
            ? SwiftUI.Color.white.opacity(0.045)
            : SwiftUI.Color.black.opacity(0.045)
    }

    var hoverFill: SwiftUI.Color {
        colorScheme == .dark
            ? SwiftUI.Color.white.opacity(0.055)
            : SwiftUI.Color.black.opacity(0.055)
    }

    var line: SwiftUI.Color {
        colorScheme == .dark
            ? SwiftUI.Color.white.opacity(0.10)
            : SwiftUI.Color.black.opacity(0.10)
    }

    var specular: SwiftUI.Color {
        colorScheme == .dark
            ? SwiftUI.Color.white.opacity(0.22)
            : SwiftUI.Color.white.opacity(0.74)
    }

    var text: SwiftUI.Color {
        colorScheme == .dark
            ? SwiftUI.Color(red: 0.96, green: 0.96, blue: 0.96)
            : SwiftUI.Color(red: 0.07, green: 0.07, blue: 0.075)
    }

    var secondaryText: SwiftUI.Color {
        colorScheme == .dark
            ? SwiftUI.Color(red: 0.72, green: 0.72, blue: 0.72)
            : SwiftUI.Color(red: 0.38, green: 0.36, blue: 0.35)
    }

    var tertiaryText: SwiftUI.Color {
        colorScheme == .dark
            ? SwiftUI.Color(red: 0.48, green: 0.48, blue: 0.48)
            : SwiftUI.Color(red: 0.50, green: 0.48, blue: 0.46)
    }

    var live: SwiftUI.Color { SwiftUI.Color(red: 0.923, green: 0.369, blue: 0.272) }
    var ready: SwiftUI.Color { SwiftUI.Color(red: 0.353, green: 0.771, blue: 0.464) }
    var warning: SwiftUI.Color { SwiftUI.Color(red: 0.967, green: 0.721, blue: 0.241) }
    var shadow: SwiftUI.Color { SwiftUI.Color.black.opacity(colorScheme == .dark ? 0.42 : 0.18) }
    var waveformBar: SwiftUI.Color { colorScheme == .dark ? SwiftUI.Color.white : SwiftUI.Color.black }
    var buttonTextOnPrimary: SwiftUI.Color { SwiftUI.Color.white }
}

private struct StatusBadge: View {
    let text: String
    let color: SwiftUI.Color
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .tracking(1)
                .foregroundStyle(color)
        }
    }
}

private struct AnimatedWaveform: View {
    let palette: RecordingPopoverPalette

    private let amplitudes: [CGFloat] = [
        0.18, 0.20, 0.23, 0.19, 0.26, 0.37, 0.45, 0.52, 0.42, 0.70, 0.92, 0.64, 0.55, 0.61,
        0.44, 0.31, 0.27, 0.30, 0.43, 0.36, 0.25, 0.29, 0.37, 0.49, 0.62, 0.46, 0.59, 0.51,
        0.47, 0.53, 0.81, 0.72, 0.63, 0.44, 0.38, 0.33, 0.26, 0.22, 0.18, 0.27, 0.34, 0.48,
        0.74, 0.88, 0.58, 0.42, 0.35, 0.29, 0.21, 0.18, 0.22, 0.31, 0.39, 0.28, 0.22, 0.18
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(amplitudes.indices, id: \.self) { i in
                    let delay = Double(i) * 0.075
                    let lift = (sin((t * 3.1) + delay) + 1) * 0.18
                    let height = max(10, 128 * min(1.0, amplitudes[i] + lift))
                    Capsule()
                        .fill(palette.waveformBar.opacity(barOpacity(at: i)))
                        .frame(width: 4, height: height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.00),
                        .init(color: .black, location: 0.09),
                        .init(color: .black, location: 0.91),
                        .init(color: .clear, location: 1.00)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        .background(
            LinearGradient(
                colors: [SwiftUI.Color.clear, palette.controlFill, SwiftUI.Color.clear],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func barOpacity(at index: Int) -> Double {
        let edge = min(index, amplitudes.count - 1 - index)
        return edge < 5 ? 0.16 + Double(edge) * 0.10 : 0.68
    }
}

private struct PrimaryPopoverButtonStyle: ButtonStyle {
    let palette: RecordingPopoverPalette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.button)
            .foregroundStyle(palette.buttonTextOnPrimary)
            .padding(.horizontal, 15)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.live.opacity(configuration.isPressed ? 0.82 : 1)))
    }
}

private struct SecondaryPopoverButtonStyle: ButtonStyle {
    let palette: RecordingPopoverPalette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.button)
            .foregroundStyle(palette.text)
            .padding(.horizontal, 15)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.controlFill.opacity(configuration.isPressed ? 1.35 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(palette.line, lineWidth: 1))
    }
}

private struct GhostPopoverButtonStyle: ButtonStyle {
    let palette: RecordingPopoverPalette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.button)
            .foregroundStyle(palette.text)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(configuration.isPressed ? palette.hoverFill : SwiftUI.Color.clear))
    }
}

private struct IconButtonStyle: ButtonStyle {
    let palette: RecordingPopoverPalette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? palette.text : palette.secondaryText)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? palette.controlFill : SwiftUI.Color.clear)
            )
    }
}

/// Single row in the recents list. Matches the canonical menu-rows
/// preview: 24x24 mono initial badge, sentence-case title, mono
/// sub-label with separator dots, right-aligned mono duration and
/// relative time. Hover background; click opens the transcript file
/// in Finder. No inline action buttons (the design's recipe doesn't
/// have them and they were creating row clutter).
private struct MenuRow: View {
    let entry: SessionFolderEnumerator.Entry
    @State private var hovering: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = RecordingPopoverPalette(colorScheme: colorScheme)
        Button(action: openTranscript) {
            HStack(alignment: .center, spacing: 10) {
                badge(palette: palette)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(DS.Font.bodySmall)
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subline)
                        .font(DS.Font.monoSmall)
                        .tracking(0.3)
                        .foregroundStyle(palette.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(relativeTime)
                    .font(DS.Font.monoSmall)
                    .tracking(0.6)
                    .foregroundStyle(palette.tertiaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? palette.hoverFill : SwiftUI.Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open transcript") { openTranscript() }
            Button("Open folder") { NSWorkspace.shared.open(entry.directory) }
        }
    }

    private func openTranscript() {
        NSWorkspace.shared.open(entry.transcript)
    }

    /// 24x24 rounded square with a single mono initial: Z for Zoom,
    /// M for Meet, etc. Inferred from the title's first letter (best
    /// effort; opaque enough for the empty / unknown case). Reference:
    /// `.integ-row .mark` is 24x24, 5pt radius, mono 11/600.
    private func badge(palette: RecordingPopoverPalette) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(palette.controlFill)
            .overlay(
                Text(initial)
                    .font(SwiftUI.Font.custom(DS.monoFamily, size: 11).weight(.semibold))
                    .foregroundStyle(palette.secondaryText)
            )
            .frame(width: 24, height: 24)
    }

    private var initial: String {
        let trimmed = entry.title.trimmingCharacters(in: .whitespaces)
        return String(trimmed.first.map { Character($0.uppercased()) } ?? "S")
    }

    /// Mono sub-label with separator dots: status and duration if
    /// known. The design preview uses this slot for "zoom · 3
    /// speakers" but we don't capture per-meeting speaker counts yet,
    /// so stick to status for now.
    private var subline: String {
        switch entry.status {
        case .complete: return "saved"
        case .pending: return "pending"
        case .retrying: return "retrying"
        case .failed: return "failed"
        }
    }

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: entry.createdAt, relativeTo: Date()).uppercased()
    }
}

private struct LevelBar: View {
    let label: String
    let value: Float
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Color.foregroundTertiary)
                .frame(width: 14)
            Text(label)
                .font(DS.Font.monoSmall)
                .tracking(0.6)
                .foregroundStyle(DS.Color.foregroundSecondary)
                .frame(width: 26, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(SwiftUI.Color.white.opacity(0.08))
                    Capsule()
                        .fill(levelColor)
                        .frame(width: max(3, proxy.size.width * CGFloat(clampedValue)))
                }
            }
            .frame(height: 4)
            Text(levelText)
                .font(DS.Font.monoSmall)
                .foregroundStyle(DS.Color.foregroundTertiary)
                .frame(width: 46, alignment: .trailing)
        }
    }

    private var clampedValue: Float { min(max(value, 0), 1) }

    private var levelColor: SwiftUI.Color {
        clampedValue <= 0.02 ? DS.Color.warning : SwiftUI.Color.white.opacity(0.92)
    }

    private var levelText: String {
        clampedValue <= 0.02 ? "silent" : "−\(Int((1 - clampedValue) * 36 + 6)) dB"
    }
}

/// `NSStatusItem.button` requires a plain `@objc` target/action pair;
/// it can't bind directly to a SwiftUI / Swift closure. This shared
/// singleton bridges from `button.action` to whatever `priorityHandler`
/// AppDelegate installs (e.g. raise a buried privacy welcome window
/// before falling through to the popover) and finally to the active
/// `RecordingMenu`'s `show(from:)`.
@MainActor
final class StatusItemClickTarget: NSObject {
    static let shared = StatusItemClickTarget()
    weak var delegate: RecordingMenu?

    /// AppDelegate sets this so a click can raise a pending privacy
    /// welcome window (or any future "modal-ish" surface) before the
    /// popover takes the click. Return `true` to consume the click.
    var priorityHandler: (@MainActor (NSStatusBarButton) -> Bool)?

    @objc func statusItemClicked(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton else { return }
        if priorityHandler?(button) == true { return }
        delegate?.show(from: button)
    }
}
