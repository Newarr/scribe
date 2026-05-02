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
final class RecordingMenu {
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

    let popover: NSPopover
    private let onAction: (Action) -> Void
    private let model: RecordingMenuModel

    init(onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
        let model = RecordingMenuModel(status: .idle)
        self.model = model
        let popover = NSPopover()
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
        self.popover = popover
        rebuild(for: .idle)
    }

    /// Status update hook (preserves the old API).
    func rebuild(for status: SessionStatus) {
        model.status = status
    }

    /// Presents the popover anchored to `button`. AppDelegate calls
    /// this in response to the status-item button click; the previous
    /// `NSStatusItem.menu` auto-presentation no longer applies.
    func show(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // Refresh recents on each open. NSPopover caches the host
        // view so this stays cheap; the enumerator only touches
        // frontmatter, never bodies.
        model.refreshRecents(under: outputRoot)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Codex UX-4: confidential UI. NSPopover hosts a backing
        // window; opt it out of screen-share captures.
        popover.contentViewController?.view.window?.sharingType = WindowChromeSharing.confidential
    }

    func close() {
        popover.performClose(nil)
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

    /// Width of the menu popover. Height is dynamic; the outer
    /// `.fixedSize(horizontal: false, vertical: true)` lets SwiftUI
    /// size to content so an empty state takes ~190pt while a full
    /// recents list pushes to ~440pt without wasting middle space.
    private let menuWidth: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(SwiftUI.Color.white.opacity(0.06))
            content
            Divider().background(SwiftUI.Color.white.opacity(0.06))
            footer
        }
        // Translucent dark surface. The popover's system vibrancy
        // chrome supplies the underlying blur; this layer adds the
        // muted dark tint and 1px hairline border that match the
        // reference's "dark but kinda liquid glass muted look."
        .background(SwiftUI.Color.black.opacity(0.40))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(SwiftUI.Color.white.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(width: menuWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(size: 18)
                .foregroundStyle(DS.Color.foreground)
            Text("scribe")
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.foreground)
            Spacer()
            statusBadge
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch model.status {
        case .recording, .stopping:
            Indicator(state: .live, label: "REC · \(timeString(model.elapsedSeconds))")
        case .starting:
            Indicator(state: .transcribing, label: "Starting")
        case .finalized:
            Indicator(state: .transcribing, label: "Saving")
        case .failed:
            Indicator(state: .failed, label: "Failed")
        case .idle:
            if model.setupNeedsAttention {
                Indicator(state: .warning, label: "Setup")
            } else {
                Indicator(state: .ready, label: "Ready")
            }
        }
    }

    // MARK: body

    @ViewBuilder
    private var content: some View {
        switch model.status {
        case .recording, .stopping, .starting, .finalized:
            recordingLayout
        case .idle, .failed:
            recentsLayout
        }
    }

    private var recordingLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Recording surface. One card carrying the source label,
            // elapsed time, and the live waveform. Matches the
            // reference design's centerpiece.
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Indicator(state: .live, label: model.recordingSourceLabel)
                    Spacer()
                    Text(timeString(model.elapsedSeconds))
                        .font(SwiftUI.Font.custom(DS.monoFamily, size: 22).weight(.semibold))
                        .foregroundStyle(DS.Color.foreground)
                        .monospacedDigit()
                }
                DSWaveform()
            }
            .padding(14)
            .background(DS.Color.backgroundCard)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .stroke(DS.Color.borderCard, lineWidth: 1)
            )
            .cornerRadius(DS.Radius.lg)

            // CAPTURING group: real-time capture facts as status
            // rows. Values come from the live model where known;
            // placeholders read "-" so the rhythm holds.
            VStack(alignment: .leading, spacing: 10) {
                DSEyebrow(text: "Capturing")
                VStack(spacing: 0) {
                    DSStatusRow("System audio", value: model.systemAudioLabel)
                    DSStatusRow("Mic",          value: model.micLabel)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var recentsLayout: some View {
        if model.recents.isEmpty {
            HStack {
                Text("No recordings yet")
                    .font(DS.Font.bodySmall)
                    .foregroundStyle(DS.Color.foregroundSecondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        } else {
            VStack(spacing: 1) {
                ForEach(model.recents, id: \.directory) { entry in
                    MenuRow(entry: entry)
                }
            }
            .padding(6)
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 8) {
            overflowMenu
            Spacer()
            primaryFooterButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var primaryFooterButton: some View {
        switch model.status {
        case .recording, .stopping:
            Button("Stop and save") { onAction(.stop) }
                .keyboardShortcut("s", modifiers: [.command])
                .buttonStyle(PrimaryButtonStyle())
        case .idle, .failed, .finalized:
            Button("Record now") { onAction(.record) }
                .keyboardShortcut("r", modifiers: [.command])
                .buttonStyle(PrimaryButtonStyle())
        case .starting:
            Button("Starting…") {}
                .buttonStyle(SecondaryButtonStyle())
                .disabled(true)
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button("Settings…")    { onAction(.openSettings) }
            Button(model.setupNeedsAttention ? "Setup required…" : "Check setup…") {
                onAction(.openSetupRequired)
            }
            Button("Diagnostics…") { onAction(.openDiagnostics) }
            Divider()
            Button("Quit")         { onAction(.quit) }
        } label: {
            Text("⋯")
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.foregroundSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(height: 28)
    }

    private func timeString(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
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

    var body: some View {
        Button(action: openTranscript) {
            HStack(alignment: .center, spacing: 10) {
                badge
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(DS.Font.bodySmall)
                        .foregroundStyle(DS.Color.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subline)
                        .font(DS.Font.monoSmall)
                        .tracking(0.3)
                        .foregroundStyle(DS.Color.foregroundTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(relativeTime)
                    .font(DS.Font.monoSmall)
                    .tracking(0.6)
                    .foregroundStyle(DS.Color.foregroundTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? DS.Color.backgroundOverlay : SwiftUI.Color.clear)
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
    private var badge: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(DS.Color.backgroundMuted)
            .overlay(
                Text(initial)
                    .font(SwiftUI.Font.custom(DS.monoFamily, size: 11).weight(.semibold))
                    .foregroundStyle(DS.Color.foregroundSecondary)
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

