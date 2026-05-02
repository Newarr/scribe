import AppKit
import SwiftUI
import TranscriberCore

/// F-5: scribe-design-system stop-prompt HUD. A floating panel with a
/// gigantic countdown numeral, mono eyebrow describing the reason, and
/// two primary buttons (`Keep recording` / `Stop now`). Replaces the
/// silent placeholder where the stop prompt was previously implicit
/// (the spec called this surface out by name as a showpiece HUD).
///
/// Lifecycle:
///   - `present(reason:secondsRemaining:onKeep:onStopNow:)` builds and
///     orders the panel front. The panel is borderless, floating, and
///     centered on the active screen.
///   - The caller drives the countdown via `update(secondsRemaining:)`
///     ticks and calls `dismiss()` when the EndGuard transitions out
///     of `.counting`.
///
/// `panel.sharingType = WindowChromeSharing.confidential` per codex UX-4.
@MainActor
final class EndCountdownWindowController {
    private var panel: NSPanel?
    private let model = EndCountdownModel()

    /// Builds the panel if needed and shows it. Subsequent calls
    /// just refresh the model (no flicker on countdown ticks).
    func present(
        reason: EndGuard.Reason,
        secondsRemaining: Int,
        onKeep: @escaping @MainActor () -> Void,
        onStopNow: @escaping @MainActor () -> Void
    ) {
        model.eyebrow = Self.eyebrow(for: reason)
        model.secondsRemaining = secondsRemaining
        model.onKeep = onKeep
        model.onStopNow = onStopNow

        if panel != nil {
            panel?.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
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
        panel.center()

        panel.contentView = NSHostingView(rootView: EndCountdownView(model: model))
        WindowChrome.installGlass(on: panel, material: .hudWindow)

        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    /// Tick the countdown without rebuilding the panel.
    func update(secondsRemaining: Int) {
        model.secondsRemaining = secondsRemaining
    }

    /// Tear down the HUD when EndGuard transitions out of `.counting`.
    func dismiss() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    private static func eyebrow(for reason: EndGuard.Reason) -> String {
        switch reason {
        case .bidirectionalSilence:
            return "Stopping · waveform silent for 30s"
        case .maxSessionDurationReached:
            return "Stopping · session reached 4 hour limit"
        }
    }
}

/// Observable backing model so countdown ticks update without forcing
/// the SwiftUI hosting view to be rebuilt every second.
@MainActor
final class EndCountdownModel: ObservableObject {
    @Published var eyebrow: String = ""
    @Published var secondsRemaining: Int = 0
    var onKeep: @MainActor () -> Void = {}
    var onStopNow: @MainActor () -> Void = {}
}

private struct EndCountdownView: View {
    @ObservedObject var model: EndCountdownModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            // Mono eyebrow in warm rust. The design's reserved live /
            // countdown signal. Custom rendering (not DSEyebrow) so the
            // foreground color is the recording rust, not the default
            // tertiary token DSEyebrow uses.
            Text(model.eyebrow.uppercased())
                .font(DS.Font.eyebrow)
                .tracking(0.44)
                .foregroundStyle(DS.Color.recording)

            // Gigantic countdown numeral. Monospaced digits keep the
            // glyph width stable so the HUD doesn't twitch each tick.
            HStack {
                Spacer()
                Text("\(max(0, model.secondsRemaining))")
                    .font(SwiftUI.Font.custom(DS.monoFamily, size: 96).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.foreground)
                Spacer()
            }

            HStack(spacing: 10) {
                Button(action: model.onKeep) {
                    Text("Keep recording").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(SecondaryButtonStyle())

                Button(action: model.onStopNow) {
                    Text("Stop now").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 360, height: 220)
        .glassBackground()
    }
}
