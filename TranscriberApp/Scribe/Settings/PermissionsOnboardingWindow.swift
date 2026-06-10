import AppKit
import SwiftUI
import TranscriberCore

/// Standalone Permissions window shown when Record is blocked by
/// missing permissions, or from the menu bar's "Setup Required..."
/// entry. Hosts the same `FidelityPermissionsPanel` content as the
/// Settings tab but in a focused, no-sidebar window with auto-polling
/// so grants made in System Settings reflect within ~1.5s when the
/// user comes back.
///
/// Replaces the deprecated `PermissionRecoveryPopoverController`
/// (menu-bar popover) which had a flashing/dismissal bug and only
/// showed unmet permissions; the window shows all four with status
/// pills so the user has a complete picture.
@MainActor
final class PermissionsOnboardingWindowController {
  private var window: NSWindow?
  private var windowDelegate: CloseCallbackWindowDelegate?
  private let onScreenRecordingRestartRequired: @MainActor () -> Void

  init(onScreenRecordingRestartRequired: @escaping @MainActor () -> Void) {
    self.onScreenRecordingRestartRequired = onScreenRecordingRestartRequired
  }

  var isShown: Bool { window?.isVisible == true }

  func present() {
    if let window {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    // Borderless + transparent background gives the SwiftUI
    // FidelityWindowSurface gradient an edge-to-edge canvas with no
    // standard macOS title bar consuming the top strip. The
    // SwiftUI body draws its own close affordance (the Done button)
    // and the close button is rendered as a hosted control in the
    // hero area; `isMovableByWindowBackground` lets the user drag
    // anywhere on the window.
    let host = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    host.title = "Scribe Setup"
    host.titleVisibility = .hidden
    host.titlebarAppearsTransparent = true
    host.isOpaque = false
    host.backgroundColor = .clear
    host.isMovableByWindowBackground = true
    host.center()
    host.isReleasedWhenClosed = false
    host.sharingType = WindowChromeSharing.confidential
    host.collectionBehavior.insert(.moveToActiveSpace)

    host.contentView = NSHostingView(
      rootView: PermissionsOnboardingView(
        onScreenRecordingRestartRequired: { [weak self] in
          self?.onScreenRecordingRestartRequired()
        },
        onClose: { [weak self] in
          self?.close()
        }
      ))
    WindowChrome.installGlass(on: host, material: .hudWindow)
    WindowChrome.makeCornersTransparent(on: host)

    let delegate = CloseCallbackWindowDelegate(onClose: { [weak self] in
      self?.window = nil
      self?.windowDelegate = nil
    })
    host.delegate = delegate

    host.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    self.window = host
    self.windowDelegate = delegate
  }

  func close() {
    window?.close()
    window = nil
    windowDelegate = nil
  }
}

private struct PermissionsOnboardingTrafficLight: View {
  let color: SwiftUI.Color
  let action: (@MainActor () -> Void)?

  var body: some View {
    Button {
      action?()
    } label: {
      Circle()
        .fill(color)
        .overlay(
          Circle()
            .strokeBorder(SwiftUI.Color.black.opacity(0.078), lineWidth: 0.5)
        )
        .frame(width: 12, height: 12)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(action == nil)
    .help(action == nil ? "" : "Close")
  }
}

private struct PermissionsOnboardingView: View {
  let onScreenRecordingRestartRequired: @MainActor () -> Void
  let onClose: @MainActor () -> Void
  #if DEBUG
    let debugPermissionStatuses: DebugPermissionStatuses?
  #endif
  @State private var requiredGranted: Bool

  #if DEBUG
    init(
      onScreenRecordingRestartRequired: @escaping @MainActor () -> Void,
      onClose: @escaping @MainActor () -> Void,
      debugPermissionStatuses: DebugPermissionStatuses? = nil
    ) {
      self.onScreenRecordingRestartRequired = onScreenRecordingRestartRequired
      self.onClose = onClose
      self.debugPermissionStatuses = debugPermissionStatuses
      _requiredGranted = State(initialValue: debugPermissionStatuses?.allRequiredGranted ?? false)
    }
  #else
    init(
      onScreenRecordingRestartRequired: @escaping @MainActor () -> Void,
      onClose: @escaping @MainActor () -> Void
    ) {
      self.onScreenRecordingRestartRequired = onScreenRecordingRestartRequired
      self.onClose = onClose
      _requiredGranted = State(initialValue: false)
    }
  #endif

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      titleBar
      VStack(alignment: .leading, spacing: 24) {
        hero
        // Mirror the Settings → Permissions tab so both
        // surfaces feel like the same family of UI. The
        // onboarding window builds its own hero + footer; the
        // panel renders just the section cards (renderIntro:
        // false), plus auto-poll so grants made in System
        // Settings reflect within ~1.5s.
        #if DEBUG
          FidelityPermissionsPanel(
            autoPoll: true,
            renderIntro: false,
            showsBypassExplainer: false,
            onScreenRecordingRestartRequired: onScreenRecordingRestartRequired,
            onRequiredStateChanged: { granted in
              requiredGranted = granted
            },
            debugStatuses: debugPermissionStatuses
          )
        #else
          FidelityPermissionsPanel(
            autoPoll: true,
            renderIntro: false,
            showsBypassExplainer: false,
            onScreenRecordingRestartRequired: onScreenRecordingRestartRequired,
            onRequiredStateChanged: { granted in
              requiredGranted = granted
            }
          )
        #endif
        footer
      }
      .padding(.top, 12)
      .padding(.horizontal, 40)
      .padding(.bottom, 32)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(width: 620, height: 620)
    .background(FidelityWindowSurface())
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(FidelitySettings.lineStrong, lineWidth: 1)
    )
  }

  // Borderless window chrome with custom 12×12 traffic light dots
  // matching the design. The close dot calls `onClose`; the
  // minimize/zoom dots are decorative-only (rendered gray to match
  // macOS's disabled-button look) because the onboarding window
  // should never be minimized or zoomed mid-setup.
  private var titleBar: some View {
    HStack(spacing: 8) {
      PermissionsOnboardingTrafficLight(
        color: SwiftUI.Color(red: 1.0, green: 0.373, blue: 0.341),
        action: onClose
      )
      PermissionsOnboardingTrafficLight(
        color: SwiftUI.Color(red: 0.851, green: 0.851, blue: 0.839),
        action: nil
      )
      PermissionsOnboardingTrafficLight(
        color: SwiftUI.Color(red: 0.851, green: 0.851, blue: 0.839),
        action: nil
      )
      Spacer(minLength: 0)
    }
    .padding(.leading, 14)
    .frame(height: 36)
  }

  private var hero: some View {
    VStack(alignment: .leading, spacing: 14) {
      ZStack {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .fill(FidelitySettings.secondaryButtonFill)
          .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
              .fill(
                LinearGradient(
                  colors: [
                    FidelitySettings.surfaceWarmTint.opacity(0.70),
                    SwiftUI.Color.clear,
                  ],
                  startPoint: .top,
                  endPoint: .bottom
                )
              )
          )
          .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
              .stroke(FidelitySettings.lineStrong, lineWidth: 1)
          )
          .shadow(color: SwiftUI.Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
        MenuHeaderMark()
          .fill(FidelitySettings.ink)
          .frame(width: 22, height: 22)
      }
      .frame(width: 44, height: 44)

      VStack(alignment: .leading, spacing: 6) {
        Text("Let's set up Scribe")
          .font(SwiftUI.Font.custom(FidelitySettings.font, size: 24).weight(.semibold))
          .foregroundStyle(FidelitySettings.ink)
          .tracking(-0.6)
        Text("Grant a few macOS permissions to capture meetings.")
          .font(FidelitySettings.subtitleFont)
          .foregroundStyle(FidelitySettings.ink2)
          .lineSpacing(4)
          .tracking(-0.08)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var footer: some View {
    HStack(alignment: .center, spacing: 6) {
      LucideIcon(glyph: .info)
        .frame(width: 12, height: 12)
        .foregroundStyle(FidelitySettings.ink3)
      Text("You can change these anytime in System Settings.")
        .font(SwiftUI.Font.custom(FidelitySettings.font, size: 11.5))
        .foregroundStyle(FidelitySettings.ink3)
        .tracking(-0.05)
      Spacer(minLength: 0)
      Button {
        if requiredGranted {
          onClose()
        }
      } label: {
        Text("Done")
          .font(SwiftUI.Font.custom(FidelitySettings.font, size: 12.5).weight(.semibold))
          .foregroundStyle(requiredGranted ? FidelitySettings.inkInverse : FidelitySettings.ink3)
          .frame(height: 28)
          .padding(.horizontal, 14)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(requiredGranted ? FidelitySettings.ink : FidelitySettings.offToggleFill)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .stroke(
                requiredGranted ? SwiftUI.Color.black.opacity(0.08) : FidelitySettings.line,
                lineWidth: 1)
          )
          .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
      .buttonStyle(.plain)
      .disabled(!requiredGranted)
      .help(requiredGranted ? "Done" : "Grant Microphone and Screen Recording first")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 4)
  }
}

#if DEBUG
  @MainActor
  enum OnboardingVisualSnapshotRenderer {
    static func renderAll(to directory: URL) throws {
      let cases: [(name: String, statuses: DebugPermissionStatuses, colorScheme: ColorScheme)] = [
        ("onboarding-without-permissions-light", .withoutPermissions, .light),
        ("onboarding-with-permissions-light", .withPermissions, .light),
        ("onboarding-without-permissions-dark", .withoutPermissions, .dark),
        ("onboarding-with-permissions-dark", .withPermissions, .dark),
      ]

      for item in cases {
        let view = PermissionsOnboardingView(
          onScreenRecordingRestartRequired: {},
          onClose: {},
          debugPermissionStatuses: item.statuses
        )
        .background(item.colorScheme == .light ? SwiftUI.Color.white : SwiftUI.Color.black)
        .environment(\.colorScheme, item.colorScheme)
        .preferredColorScheme(item.colorScheme)
        try DebugVisualSnapshotWriter.write(view, named: item.name, to: directory)
      }

      let keyView = OnboardingSnapshotStepView(step: .elevenLabsAPIKey, localPath: false)
        .background(SwiftUI.Color.white)
        .environment(\.colorScheme, ColorScheme.light)
        .preferredColorScheme(.light)
      try DebugVisualSnapshotWriter.write(
        keyView,
        named: "onboarding-elevenlabs-key-entry-light",
        to: directory
      )

      let localView = OnboardingSnapshotStepView(step: .chooseEngine, localPath: true)
        .background(SwiftUI.Color.white)
        .environment(\.colorScheme, ColorScheme.light)
        .preferredColorScheme(.light)
      try DebugVisualSnapshotWriter.write(
        localView,
        named: "onboarding-skip-to-local-readiness-light",
        to: directory
      )
    }
  }

  private struct OnboardingSnapshotStepView: View {
    let step: OnboardingFlowStep
    let localPath: Bool
    @State private var pendingKey = ""

    var body: some View {
      VStack(alignment: .leading, spacing: 22) {
        HStack {
          Indicator(state: .ready, label: "ONBOARD")
          Spacer()
          Text(localPath ? "Skip to Local" : "Key entry")
            .font(DS.Font.monoSmall)
            .foregroundStyle(DS.Color.foregroundTertiary)
        }
        Text(title)
          .font(DS.Font.title)
          .foregroundStyle(DS.Color.foreground)
        Text(detail)
          .font(DS.Font.body)
          .foregroundStyle(DS.Color.foregroundSecondary)
          .fixedSize(horizontal: false, vertical: true)
        bodyContent
        Spacer()
        HStack {
          Button(localPath ? "Skip" : "Skip") {}
            .buttonStyle(SecondaryButtonStyle())
          Spacer()
          Button(localPath ? "Continue with Local" : "Save key") {}
            .buttonStyle(PrimaryButtonStyle())
        }
      }
      .padding(40)
      .frame(width: 720, height: 620)
      .glassBackground()
    }

    @ViewBuilder private var bodyContent: some View {
      if step == .elevenLabsAPIKey {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text("Paste ElevenLabs API key…")
              .font(DS.Font.body)
              .foregroundStyle(DS.Color.foregroundTertiary)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 12)
          .frame(height: 38)
          .background(RoundedRectangle(cornerRadius: 7).fill(DS.Color.backgroundDeep))
          .overlay(RoundedRectangle(cornerRadius: 7).stroke(DS.Color.borderStrong, lineWidth: 1))
          .accessibilityLabel("ElevenLabs API key")
          Text("The key is stored securely in macOS Keychain and is not saved to any file.")
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.foregroundSecondary)
        }
      } else {
        VStack(alignment: .leading, spacing: 12) {
          engineSnapshotRow(title: "ElevenLabs (Cloud)", status: "API key required", ready: false)
          engineSnapshotRow(
            title: "Cohere (local)",
            status: "Downloading model · Local setup continues",
            ready: false
          )
          Text("Skipping the Cloud key keeps setup moving toward Cohere local transcription.")
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.foregroundSecondary)
        }
      }
    }

    private func engineSnapshotRow(title: String, status: String, ready: Bool) -> some View {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(DS.Font.bodyEmphasis)
          Text(status).font(DS.Font.caption)
        }
        Spacer()
        Text(ready ? "READY" : "WAIT")
          .font(DS.Font.monoSmall)
      }
      .padding(12)
      .background(RoundedRectangle(cornerRadius: 10).fill(DS.Color.backgroundCard))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(DS.Color.border, lineWidth: 1))
    }

    private var title: String { localPath ? "Cohere local setup" : "ElevenLabs API key" }
    private var detail: String {
      localPath
        ? "Scribe will keep working without a Cloud key and use Cohere local once the model verifies."
        : "Cloud transcription is optional. Enter a key for ElevenLabs, or skip to use Cohere local once it verifies."
    }
  }
#endif
