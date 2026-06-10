import SwiftUI
import TranscriberCore

struct RecordingPopoverContent: View {
  @ObservedObject var model: RecordingMenuModel
  let onAction: (RecordingMenu.Action) -> Void
  let animatesAppearance: Bool

  private let menuWidth: CGFloat = 420
  @SwiftUI.State private var didAppear: Bool = false
  @Environment(\.colorScheme) private var colorScheme
  private let menuHeadingFont = SwiftUI.Font.custom(DS.sansFamily, size: 16).weight(.semibold)

  init(
    model: RecordingMenuModel,
    animatesAppearance: Bool = true,
    onAction: @escaping (RecordingMenu.Action) -> Void
  ) {
    self.model = model
    self.animatesAppearance = animatesAppearance
    self.onAction = onAction
  }

  var body: some View {
    let resolvedColorScheme = model.appearanceTheme.preferredColorScheme ?? colorScheme
    let palette = RecordingPopoverPalette(colorScheme: resolvedColorScheme)
    VStack(spacing: 0) {
      header(palette: palette)
      Rectangle()
        .fill(palette.dividerLine)
        .frame(height: 1)
      content(palette: palette)
    }
    .frame(width: menuWidth, alignment: .top)
    .frame(minHeight: minimumSurfaceHeight, alignment: .top)
    .fixedSize(horizontal: false, vertical: true)
    .background(PopoverSurfaceBackground(palette: palette))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(palette.outerStroke, lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .shadow(color: palette.shadow, radius: palette.shadowRadius, x: 0, y: palette.shadowYOffset)
    .opacity(animatesAppearance ? (didAppear ? 1 : 0) : 1)
    .offset(y: animatesAppearance ? (didAppear ? 0 : -6) : 0)
    .animation(animatesAppearance ? .easeOut(duration: 0.18) : nil, value: didAppear)
    .onAppear {
      if animatesAppearance {
        didAppear = true
      }
    }
    .environment(\.colorScheme, resolvedColorScheme)
    .preferredColorScheme(model.appearanceTheme.preferredColorScheme)
  }

  private var minimumSurfaceHeight: CGFloat? {
    switch model.status {
    case .idle:
      if model.pendingPrompt != nil { return 244 }
      if model.setupNeedsAttention { return 167 }
      return model.recents.isEmpty ? nil : 336
    case .starting:
      return 365
    case .recording:
      if model.endPrompt != nil { return model.queuedNextMeeting == nil ? 440 : 476 }
      return model.queuedNextMeeting == nil ? 356 : 392
    case .stopping:
      return model.queuedNextMeeting == nil ? 386 : 422
    case .finalized:
      return model.queuedNextMeeting == nil ? 340 : 376
    case .failed:
      return 196
    }
  }

  private func header(palette: RecordingPopoverPalette) -> some View {
    HStack(spacing: 6) {
      MenuHeaderMark()
        .fill(palette.text)
        .frame(width: 18, height: 18)
      Text("scribe")
        .font(DS.Font.subheading)
        .foregroundStyle(palette.text)
      Spacer()
      StatusBadge(
        text: headerStatusText,
        color: headerStatusColor(palette: palette)
      )
    }
    .padding(.horizontal, 20)
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
      if model.pendingPrompt != nil {
        pendingPromptLayout(palette: palette)
      } else {
        idleLayout(palette: palette)
      }
    }
  }

  private func pendingPromptLayout(palette: RecordingPopoverPalette) -> some View {
    let prompt = model.pendingPrompt
    return VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        Text("Meeting detected")
          .font(menuHeadingFont)
          .foregroundStyle(palette.text)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text(prompt?.subtitle ?? "Scribe detected an active call. Choose whether to record.")
          .font(DS.Font.bodySmall)
          .foregroundStyle(palette.secondaryText)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack(spacing: 8) {
        LucideIcon(glyph: .info)
          .frame(width: 12, height: 12)
          .foregroundStyle(palette.warning)
        Text(prompt?.title ?? "Pending meeting")
          .font(DS.Font.monoSmall)
          .foregroundStyle(palette.metaText)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .padding(.horizontal, 10)
      .frame(height: 30)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(palette.controlFill)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(palette.controlStroke, lineWidth: 1)
      )
      VStack(alignment: .leading, spacing: 6) {
        DisclosureGroup("More options ▾") {
          Button("Stop detecting \(prompt?.appDisplayName ?? "this app") for 30 minutes") {
            onAction(.promptSuppressApp)
          }
          .buttonStyle(GhostPopoverButtonStyle(palette: palette))
        }
        .font(DS.Font.bodySmall)
        .foregroundStyle(palette.secondaryText)
      }
      HStack(spacing: 8) {
        settingsGear(palette: palette)
        Spacer()
        Button("Not now") { onAction(.promptNotNow) }
          .buttonStyle(SecondaryPopoverButtonStyle(palette: palette))
        Button("Start Recording") { onAction(.promptStartRecording) }
          .keyboardShortcut("r", modifiers: [.command])
          .buttonStyle(PrimaryPopoverButtonStyle(palette: palette))
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 16)
  }

  private func idleLayout(palette: RecordingPopoverPalette) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        Text(model.setupNeedsAttention ? "Setup needs attention" : "Ready to record")
          .font(menuHeadingFont)
          .foregroundStyle(palette.text)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text(
          model.setupNeedsAttention
            ? "Open setup to finish permissions. The setup window will reopen even if you closed it."
            : "Scribe will prompt for meetings, or you can start now."
        )
        .font(DS.Font.bodySmall)
        .foregroundStyle(palette.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      if model.setupNeedsAttention {
        HStack(spacing: 8) {
          LucideIcon(glyph: .alertTriangle)
            .frame(width: 13, height: 13)
            .foregroundStyle(palette.warning)
          Text("Microphone, System Audio Recording, Calendar, or Notifications may need attention.")
            .font(DS.Font.monoSmall)
            .foregroundStyle(palette.metaText)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(palette.controlFill)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(palette.controlStroke, lineWidth: 1)
        )
      } else if model.recents.isEmpty {
        EmptyView()
      } else {
        VStack(spacing: 1) {
          ForEach(model.recents, id: \.directory) { entry in
            MenuRow(
              entry: entry,
              onRetry: { sessionURL in
                onAction(.retryRecentFailedSession(sessionURL))
              },
              onRepair: { sessionURL in
                onAction(.repairRecentFailedSession(sessionURL))
              },
              localModelReadyForRetry: model.localModelReadyForRetry
            )
          }
        }
        .padding(6)
        .background(palette.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(palette.controlStroke, lineWidth: 1)
        )
      }
      HStack(spacing: 8) {
        settingsGear(palette: palette)
        Spacer()
        if model.setupNeedsAttention {
          Button("Record now") { onAction(.record) }
            .keyboardShortcut("r", modifiers: [.command])
            .buttonStyle(SecondaryPopoverButtonStyle(palette: palette))
          Button("Open setup") { onAction(.openSetupRequired) }
            .keyboardShortcut("s", modifiers: [.command])
            .buttonStyle(PrimaryPopoverButtonStyle(palette: palette))
        } else {
          Button("Record now") { onAction(.record) }
            .keyboardShortcut("r", modifiers: [.command])
            .buttonStyle(PrimaryPopoverButtonStyle(palette: palette))
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 16)
  }

  private func recordingLayout(palette: RecordingPopoverPalette) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Circle().fill(model.endPrompt == nil ? palette.live : palette.warning).frame(
          width: 8, height: 8)
        Text(model.recordingSourceLabel)
          .font(menuHeadingFont)
          .foregroundStyle(palette.text)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer()
        Text(timeString(model.elapsedSeconds))
          .font(SwiftUI.Font.custom(DS.monoFamily, size: 17).weight(.regular))
          .foregroundStyle(palette.text)
          .monospacedDigit()
      }
      AnimatedWaveform(
        palette: palette,
        isAnimating: shouldAnimateWaveform,
        isActive: shouldAnimateWaveform
      )
      .frame(height: 68)
      .accessibilityHidden(true)
      HStack(alignment: .center, spacing: 10) {
        Text(activeStatusCopy)
          .font(activeStatusFont)
          .foregroundStyle(palette.secondaryText)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
        CompactAudioActivity(
          micLevel: model.micLevel,
          systemLevel: model.systemLevel,
          palette: palette
        )
      }
      .accessibilityElement(children: .contain)
      privacyStatusBlock(palette: palette)
      if let endPrompt = model.endPrompt {
        endPromptBlock(endPrompt, palette: palette)
      }
      if let queued = model.queuedNextMeeting {
        HStack(spacing: 8) {
          LucideIcon(glyph: .calendar)
            .frame(width: 12, height: 12)
          Text("Next: '\(queued.title)' at \(queued.time)")
            .font(DS.Font.monoSmall)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .foregroundStyle(palette.metaText)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(palette.controlFill)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(palette.controlStroke, lineWidth: 1)
        )
      }
      HStack(spacing: 8) {
        settingsGear(palette: palette)
        Spacer()
        if let endPrompt = model.endPrompt {
          Button("Stop now") { onAction(.endPromptStopNow(generation: endPrompt.generation)) }
            .buttonStyle(SecondaryPopoverButtonStyle(palette: palette))
          Button("Keep recording") {
            onAction(.endPromptKeepRecording(generation: endPrompt.generation))
          }
          .keyboardShortcut("k", modifiers: [.command])
          .buttonStyle(PrimaryPopoverButtonStyle(palette: palette))
        } else if activeActionIsPrimary {
          Button(activeActionTitle) {
            if !activeActionIsDisabled { onAction(.stop) }
          }
          .keyboardShortcut("s", modifiers: [.command])
          .buttonStyle(
            PrimaryPopoverButtonStyle(palette: palette, textColor: palette.activePrimaryButtonText))
        } else {
          Button(activeActionTitle) {
            if !activeActionIsDisabled { onAction(.stop) }
          }
          .keyboardShortcut("s", modifiers: [.command])
          .buttonStyle(SecondaryPopoverButtonStyle(palette: palette))
          .allowsHitTesting(!activeActionIsDisabled)
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 16)
  }

  private func endPromptBlock(_ prompt: RecordingMenuEndPrompt, palette: RecordingPopoverPalette)
    -> some View
  {
    HStack(spacing: 10) {
      Text("\(max(0, prompt.secondsRemaining))")
        .font(SwiftUI.Font.custom(DS.monoFamily, size: 32).weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(palette.warning)
        .frame(width: 48, alignment: .leading)
      VStack(alignment: .leading, spacing: 3) {
        Text("Call seems over")
          .font(SwiftUI.Font.custom(DS.sansFamily, size: 14).weight(.semibold))
          .foregroundStyle(palette.text)
        Text("Scribe will stop unless you keep recording.")
          .font(DS.Font.monoSmall)
          .foregroundStyle(palette.metaText)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer()
    }
    .padding(.horizontal, 10)
    .frame(height: 54)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(palette.controlFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(palette.controlStroke, lineWidth: 1)
    )
    .accessibilityLabel(
      "Stopping soon, \(max(0, prompt.secondsRemaining)) seconds remaining, \(prompt.reason)")
  }

  private func privacyStatusBlock(palette: RecordingPopoverPalette) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Audio: local · \(model.outcomeFolderName ?? "Scribe session")")
      Text("Captured: mic + system audio · no video, no screenshots")
      Text("Engine: \(activeEngineLabel)")
    }
    .font(DS.Font.monoSmall)
    .foregroundStyle(palette.metaText)
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(palette.controlFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(palette.controlStroke, lineWidth: 1)
    )
  }

  private var activeEngineLabel: String {
    switch model.sessionEngineMode {
    case .local: return "Cohere (local)"
    case .cloud: return "ElevenLabs (cloud)"
    }
  }

  private var activeStatusCopy: String {
    if let endPrompt = model.endPrompt {
      return "Stopping soon · \(endPrompt.reason). Capture is still live."
    }
    switch (model.status, model.sessionEngineMode) {
    case (.stopping, _):
      return "Saving into \(outputTargetName)"
    case (.finalized, _):
      return "Transcribing into \(outputTargetName)"
    case (_, .local):
      return "Recording into \(outputTargetName) · Cohere stays on this Mac"
    case (_, .cloud):
      return "Recording into \(outputTargetName) · ElevenLabs after stop"
    }
  }

  private var outputTargetName: String {
    guard let folder = model.outcomeFolderName, !folder.isEmpty else {
      return "transcript.md"
    }
    return "\(folder)/transcript.md"
  }

  private var audioCaptureIsActive: Bool {
    channelIsActive(model.micLevel) && channelIsActive(model.systemLevel)
  }

  private var shouldAnimateWaveform: Bool {
    model.status == .recording && audioCaptureIsActive
  }

  private func channelIsActive(_ level: Float) -> Bool {
    level > 0.01
  }

  private var activeStatusFont: SwiftUI.Font {
    if model.endPrompt != nil {
      return DS.Font.body
    }
    switch model.status {
    case .recording, .starting:
      return SwiftUI.Font.custom(DS.sansFamily, size: 13).weight(.regular)
    case .stopping, .finalized, .idle, .failed:
      return DS.Font.body
    }
  }

  private var activeActionTitle: String {
    switch model.status {
    case .stopping:
      return "Stopping…"
    default:
      return "Stop now"
    }
  }

  private var activeActionIsPrimary: Bool {
    switch model.status {
    case .recording, .starting:
      return true
    case .stopping, .finalized, .failed, .idle:
      return false
    }
  }

  private var activeActionIsDisabled: Bool {
    switch model.status {
    case .stopping, .finalized:
      return true
    case .idle, .starting, .recording, .failed:
      return false
    }
  }

  private func settingsGear(palette: RecordingPopoverPalette) -> some View {
    Button {
      onAction(.openSettings)
    } label: {
      LucideIcon(glyph: .settings)
        .frame(width: 16, height: 16)
        .frame(width: 32, height: 32)
        .contentShape(Rectangle())
    }
    .buttonStyle(IconButtonStyle(palette: palette))
    .help("Open Settings")
  }

  private func failedLayout(palette: RecordingPopoverPalette) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        LucideIcon(glyph: .alertTriangle)
          .frame(width: 16, height: 16)
          .foregroundStyle(palette.warning)
        Text("Transcription failed")
          .font(menuHeadingFont)
          .foregroundStyle(palette.text)
      }
      Text("Transcription failed, but the recording remains on disk and can be retried.")
        .font(DS.Font.bodySmall)
        .foregroundStyle(palette.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 8) {
        settingsGear(palette: palette)
        Spacer()
        Button("Retry") { onAction(.retryFailedSession) }
          .buttonStyle(PrimaryPopoverButtonStyle(palette: palette))
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 16)
  }

  private var headerStatusText: String {
    if let endPrompt = model.endPrompt {
      return "STOPPING \(max(0, endPrompt.secondsRemaining))"
    }
    switch model.status {
    case .recording, .stopping: return "LIVE"
    case .starting: return "STARTING"
    case .finalized: return "TRANSCRIBING"
    case .failed: return "FAILED"
    case .idle:
      if model.pendingPrompt != nil { return "DETECTED" }
      return model.setupNeedsAttention ? "SETUP" : "READY"
    }
  }

  private func headerStatusColor(palette: RecordingPopoverPalette) -> SwiftUI.Color {
    if model.endPrompt != nil {
      return palette.warning
    }
    switch model.status {
    case .recording, .stopping: return palette.live
    case .failed: return palette.warning
    case .idle:
      return (model.pendingPrompt != nil || model.setupNeedsAttention)
        ? palette.warning : palette.ready
    default: return palette.neutralStatus
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

#if DEBUG
  @MainActor
  enum RecordingMenuVisualSnapshotRenderer {
    static func renderAll(to directory: URL) throws {
      let recentsRoot = try makeRecentsRoot()
      let recents = SessionFolderEnumerator.recents(
        under: recentsRoot, limit: RecordingMenuModel.recentsLimit)
      let cases: [(name: String, theme: AppearanceTheme, model: RecordingMenuModel)] = [
        ("menu-setup-light", .light, idleModel(setupNeedsAttention: true, recents: [])),
        ("menu-ready-light", .light, idleModel(setupNeedsAttention: false, recents: recents)),
        (
          "menu-recording-light", .light,
          activeModel(status: .recording, elapsed: 261, source: "Zoom · Design review")
        ),
        (
          "menu-starting-light", .light,
          activeModel(status: .starting, elapsed: 0, source: "Recording", folderName: nil)
        ),
        (
          "menu-stopping-light", .light,
          activeModel(status: .stopping, elapsed: 2838, source: "Zoom · Design review")
        ),
        (
          "menu-finalized-light", .light,
          activeModel(status: .finalized, elapsed: 2838, source: "Zoom · Design review")
        ),
        ("menu-failed-light", .light, failedModel()),
        ("menu-setup-dark", .dark, idleModel(setupNeedsAttention: true, recents: [])),
        ("menu-ready-dark", .dark, idleModel(setupNeedsAttention: false, recents: recents)),
        (
          "menu-recording-dark", .dark,
          activeModel(status: .recording, elapsed: 261, source: "Zoom · Design review")
        ),
        (
          "menu-starting-dark", .dark,
          activeModel(status: .starting, elapsed: 0, source: "Recording", folderName: nil)
        ),
        (
          "menu-stopping-dark", .dark,
          activeModel(status: .stopping, elapsed: 2838, source: "Zoom · Design review")
        ),
        (
          "menu-finalized-dark", .dark,
          activeModel(status: .finalized, elapsed: 2838, source: "Zoom · Design review")
        ),
        ("menu-failed-dark", .dark, failedModel()),
      ]

      for item in cases {
        item.model.appearanceTheme = item.theme
        let view = RecordingPopoverContent(
          model: item.model,
          animatesAppearance: false,
          onAction: { _ in }
        )
        .padding(20)
        .background(Color.black)
        try DebugVisualSnapshotWriter.write(view, named: item.name, to: directory)
      }
    }

    private static func idleModel(
      setupNeedsAttention: Bool,
      recents: [SessionFolderEnumerator.Entry]
    ) -> RecordingMenuModel {
      let model = RecordingMenuModel(status: .idle)
      model.setupNeedsAttention = setupNeedsAttention
      model.recents = recents
      return model
    }

    private static func activeModel(
      status: SessionStatus,
      elapsed: Int,
      source: String,
      folderName: String? = "2026-05-07 09:41 - Design review"
    ) -> RecordingMenuModel {
      let model = RecordingMenuModel(status: status)
      model.recordingSourceLabel = source
      model.elapsedSeconds = elapsed
      model.sessionEngineMode = .cloud
      model.micLevel = 0.72
      model.systemLevel = 0.58
      model.outcomeFolderName = folderName
      if let folderName {
        model.outcomeFolderURL = URL(fileURLWithPath: "/tmp/\(folderName)", isDirectory: true)
      }
      return model
    }

    private static func failedModel() -> RecordingMenuModel {
      let model = RecordingMenuModel(status: .failed)
      model.outcomeFolderName = "2026-05-07 09:41 - Design review"
      model.outcomeFolderURL = URL(
        fileURLWithPath: "/tmp/2026-05-07 09:41 - Design review", isDirectory: true)
      return model
    }

    private static func makeRecentsRoot() throws -> URL {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("scribe-menu-visual-recents", isDirectory: true)
      try? FileManager.default.removeItem(at: root)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let now = Date()
      try writeSession(
        root: root,
        directoryName: "2026-05-11 09:00 - Acme Q3 sync",
        title: "Acme Q3 sync",
        modified: now.addingTimeInterval(-2 * 60 * 60)
      )
      try writeSession(
        root: root,
        directoryName: "2026-05-10 14:00 - Design review",
        title: "Design review",
        modified: now.addingTimeInterval(-24 * 60 * 60)
      )
      try writeSession(
        root: root,
        directoryName: "2026-05-08 10:30 - Karen 1:1",
        title: "Karen 1:1",
        modified: now.addingTimeInterval(-3 * 24 * 60 * 60)
      )
      return root
    }

    private static func writeSession(
      root: URL,
      directoryName: String,
      title: String,
      modified: Date
    ) throws {
      let directory = root.appendingPathComponent(directoryName, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let transcript = directory.appendingPathComponent("transcript.md")
      let body = """
        ---
        status: complete
        title: "\(title)"
        engine: elevenlabs
        ---

        body
        """
      try body.write(to: transcript, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.modificationDate: modified], ofItemAtPath: directory.path)
    }
  }
#endif
