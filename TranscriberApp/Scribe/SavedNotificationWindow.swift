import AppKit
import SwiftUI
import TranscriberCore

/// F-7: scribe-design-system "saved" confirmation panel. Floats at the
/// top-right of the active screen for 6 seconds after a successful
/// save, with a hairline progress indicator at the bottom edge that
/// drains down to zero. Hover suspends the dismiss timer so a user
/// who reaches for the panel keeps it open.
@MainActor
final class SavedNotificationWindowController {
    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private let autoDismissDuration: TimeInterval = 6.0

    /// Tearable summary the panel presents. `sizeBytes` is the total
    /// of the audio file's size on disk; `durationSeconds` comes from
    /// the session frontmatter. `engineLabel` is "ElevenLabs",
    /// "Local", etc. for the metadata caption.
    struct Summary: Equatable {
        var title: String
        var durationSeconds: Int
        var sizeBytes: Int64
        var engineLabel: String
        var folderURL: URL?
        var transcriptURL: URL?
    }

    func present(_ summary: Summary) {
        dismissTimer?.invalidate()

        let model = SavedNotificationModel(summary: summary)

        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 130),
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.sharingType = WindowChromeSharing.confidential

            // Anchor top-right of the visible frame on the active
            // screen, leaving 18pt padding from each edge.
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameTopLeftPoint(NSPoint(
                    x: frame.maxX - 360 - 18,
                    y: frame.maxY - 18
                ))
            }

            panel.contentView = NSHostingView(rootView: SavedNotificationView(
                model: model,
                onOpenFolder: { [weak self] in
                    if let url = summary.folderURL { NSWorkspace.shared.open(url) }
                    self?.dismiss()
                },
                onOpenTranscript: { [weak self] in
                    if let url = summary.transcriptURL { NSWorkspace.shared.open(url) }
                    self?.dismiss()
                },
                onPauseAutoDismiss: { [weak self] in self?.pauseDismiss() },
                onResumeAutoDismiss: { [weak self] in self?.scheduleDismiss() }
            ))
            WindowChrome.installGlass(on: panel, material: .hudWindow)

            self.panel = panel
        }
        panel?.orderFrontRegardless()
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: autoDismissDuration,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    private func pauseDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

@MainActor
final class SavedNotificationModel: ObservableObject {
    @Published var summary: SavedNotificationWindowController.Summary
    init(summary: SavedNotificationWindowController.Summary) {
        self.summary = summary
    }

    /// "54 min · 47 MB · ElevenLabs"
    var metaCaption: String {
        let minutes = max(1, summary.durationSeconds / 60)
        let mb = max(0, Int((Double(summary.sizeBytes) / 1_048_576).rounded()))
        return "\(minutes) min · \(mb) MB · \(summary.engineLabel)"
    }
}

private struct SavedNotificationView: View {
    @ObservedObject var model: SavedNotificationModel
    let onOpenFolder: @MainActor () -> Void
    let onOpenTranscript: @MainActor () -> Void
    let onPauseAutoDismiss: @MainActor () -> Void
    let onResumeAutoDismiss: @MainActor () -> Void
    @State private var hovering: Bool = false
    /// Drives the entrance fade + slide. Spec page-level transition
    /// is "200ms fade + 8px translate-y"; we ease in from the right
    /// edge instead since the panel anchors top-right.
    @State private var didAppear: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Indicator(state: .sent, label: "Saved")
            Text(model.summary.title)
                .font(DS.Font.subheading)
                .foregroundStyle(DS.Color.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(model.metaCaption)
                .font(DS.Font.monoSmall)
                .foregroundStyle(DS.Color.foregroundTertiary)
            HStack(spacing: 6) {
                Button(action: onOpenFolder) { Text("Open folder") }
                    .buttonStyle(GhostButtonStyle())
                Button(action: onOpenTranscript) { Text("Open transcript") }
                    .buttonStyle(GhostButtonStyle())
                Spacer()
            }
            // Hairline progress indicator (6s drain). Re-keyed on
            // every render so hover-pause-resume restarts the drain.
            ProgressTimeline(duration: 6.0, paused: hovering)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 360, height: 130, alignment: .topLeading)
        .glassBackground()
        .opacity(didAppear ? 1 : 0)
        .offset(x: didAppear ? 0 : 12)
        .animation(.easeOut(duration: 0.22), value: didAppear)
        .onAppear { didAppear = true }
        .onHover { isHovering in
            hovering = isHovering
            if isHovering { onPauseAutoDismiss() } else { onResumeAutoDismiss() }
        }
    }
}

private struct ProgressTimeline: View {
    let duration: Double
    let paused: Bool
    @State private var width: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(DS.Color.success)
                .frame(width: geo.size.width * width, height: 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onAppear { animate() }
                .onChange(of: paused) { _, newPaused in
                    if newPaused { width = width } else { animate() }
                }
        }
        .frame(height: 1)
    }

    private func animate() {
        withAnimation(.linear(duration: duration)) {
            width = 0
        }
    }
}
