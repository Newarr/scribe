import AppKit
import SwiftUI
import TranscriberCore

/// Maps a `PreflightReason` to a label, an explainer, and (where
/// applicable) the System Settings deep-link URL that lets the user fix
/// it. Phase α surfaces the typed reasons; Phase η renders them as a
/// popover so the user can act on each one without leaving the app.
enum PermissionRemediation {
    struct Step: Identifiable, Hashable {
        let id: String
        let title: String
        let detail: String
        let openURL: URL?
        let kind: Kind

        enum Kind: String, Hashable {
            case blocker
            case warning
        }
    }

    static func steps(from report: PreflightReport) -> [Step] {
        var out: [Step] = []
        for r in report.blockers {
            out.append(stepFor(r, kind: .blocker))
        }
        for r in report.warnings {
            out.append(stepFor(r, kind: .warning))
        }
        return out
    }

    private static func stepFor(_ reason: PreflightReason, kind: Step.Kind) -> Step {
        switch reason {
        case .microphoneDenied:
            return Step(
                id: "mic.denied",
                title: "Microphone access denied",
                detail: "Transcriber can't capture your voice without microphone permission. Open System Settings → Privacy & Security → Microphone, then enable Transcriber.",
                openURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"),
                kind: kind
            )
        case .microphoneNotDetermined:
            return Step(
                id: "mic.undetermined",
                title: "Microphone permission not granted yet",
                detail: "Click Record once and macOS will prompt for microphone access. Grant it and then start a session.",
                openURL: nil,
                kind: kind
            )
        case .screenRecordingDenied:
            return Step(
                id: "screen.denied",
                title: "Screen recording access denied",
                detail: "Transcriber needs screen recording permission to capture other apps' audio (Zoom, Meet, etc). Open System Settings → Privacy & Security → Screen Recording, enable Transcriber, and restart the app.",
                openURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
                kind: kind
            )
        case .outputFolderUnwritable(let url):
            return Step(
                id: "output.unwritable",
                title: "Output folder isn't writable",
                detail: "Transcriber can't write to \(url.path). Pick a different folder under Settings → Output, or fix the permissions on this one.",
                openURL: nil,
                kind: kind
            )
        case .outputFolderInSyncedStorage(let url, let provider):
            return Step(
                id: "output.synced",
                title: "Output folder is in \(provider)",
                detail: "Recording into \(provider) at \(url.path) can race the cloud sync (truncated audio mid-write). Move the folder to local storage, or accept the risk.",
                openURL: nil,
                kind: kind
            )
        case .missingCloudAPIKey:
            return Step(
                id: "cloud.api-key",
                title: "ElevenLabs API key missing",
                detail: "Cloud mode needs an API key in your Keychain. Open Settings → Engine and paste the key there, or switch to local mode once the local engine ships.",
                openURL: nil,
                kind: kind
            )
        case .localEngineNotConfigured:
            return Step(
                id: "local.engine.unconfigured",
                title: "Local engine binary path not configured",
                detail: "Local mode is selected but no Cohere binary path is set. Settings → Engine.",
                openURL: nil,
                kind: kind
            )
        case .missingLocalEngineBinary(let url):
            return Step(
                id: "local.engine.binary",
                title: "Local engine binary missing",
                detail: "Expected the Cohere binary at \(url.path). Reinstall Transcriber or switch to cloud mode.",
                openURL: nil,
                kind: kind
            )
        case .localLanguageModelNotConfigured:
            return Step(
                id: "local.lang-model.unconfigured",
                title: "Language detection model path not configured",
                detail: "The local engine needs a language-detection model (Whisper-tiny). Settings → Engine.",
                openURL: nil,
                kind: kind
            )
        case .missingLocalLanguageModel(let url):
            return Step(
                id: "local.lang-model",
                title: "Language detection model missing",
                detail: "Expected the Whisper-tiny model at \(url.path). Reinstall Transcriber or switch to cloud mode.",
                openURL: nil,
                kind: kind
            )
        case .calendarDeniedOptional:
            return Step(
                id: "calendar.denied",
                title: "Calendar access denied (optional)",
                detail: "Without calendar access, sessions won't be tagged with the meeting title or attendees. Recording still works. Open System Settings → Privacy & Security → Calendars to enable.",
                openURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"),
                kind: kind
            )
        case .calendarNotDetermined:
            return Step(
                id: "calendar.undetermined",
                title: "Calendar permission not granted yet (optional)",
                detail: "Click Record once and macOS will prompt for calendar access. Grant it for richer session metadata.",
                openURL: nil,
                kind: kind
            )
        }
    }
}

/// Popover content showing a Setup Required summary plus per-reason
/// remediation buttons. Triggered from AppDelegate when preflight
/// returns `.deny`, also accessible from the menu bar so the user can
/// recheck after fixing things in System Settings.
struct PermissionRecoveryView: View {
    let steps: [PermissionRemediation.Step]
    let onRecheck: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Setup Required")
                    .font(.headline)
                Spacer()
            }

            if steps.isEmpty {
                Text("Everything looks good. Try Record again.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(steps, id: \.id) { step in
                        StepRow(step: step)
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Recheck", action: onRecheck)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}

private struct StepRow: View {
    let step: PermissionRemediation.Step

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: step.kind == .blocker ? "octagon.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(step.kind == .blocker ? .red : .yellow)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title).fontWeight(.semibold)
                    Text(step.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let url = step.openURL {
                HStack {
                    Spacer()
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(url)
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

/// Lightweight controller that hosts a `PermissionRecoveryView` inside
/// an `NSPopover` anchored to the menu bar status item. Centralized so
/// AppDelegate doesn't have to manage NSPopover lifecycle.
@MainActor
final class PermissionRecoveryPopoverController {
    private let popover = NSPopover()

    func show(
        steps: [PermissionRemediation.Step],
        anchor: NSStatusBarButton,
        onRecheck: @escaping @MainActor () -> Void
    ) {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 460, height: 320)
        popover.contentViewController = NSHostingController(
            rootView: PermissionRecoveryView(steps: steps, onRecheck: { [weak popover] in
                popover?.performClose(nil)
                onRecheck()
            })
        )
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func close() {
        popover.performClose(nil)
    }
}
