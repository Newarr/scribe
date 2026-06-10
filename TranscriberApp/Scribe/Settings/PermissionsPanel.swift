import AppKit
import CoreGraphics
import SwiftUI
import TranscriberCore
import UserNotifications

/// Backing state for the polished Permissions panel. Shared between the
/// Settings tab (one-shot refresh) and the standalone Permissions
/// onboarding window (auto-poll + becomes-active observer). The model
/// owns the four permission statuses, the request handlers that fire
/// in-app system prompts, and the screen-recording restart-required
/// signal that AppDelegate maps to the relaunch alert.
struct DebugPermissionStatuses {
  let microphone: PermissionStatus
  let screenRecording: PermissionStatus
  let calendar: PermissionStatus
  let notifications: PermissionStatus

  var allRequiredGranted: Bool {
    microphone == .granted && screenRecording == .granted
  }

  static let withoutPermissions = DebugPermissionStatuses(
    microphone: .notDetermined,
    screenRecording: .denied,
    calendar: .notDetermined,
    notifications: .notDetermined
  )

  static let withPermissions = DebugPermissionStatuses(
    microphone: .granted,
    screenRecording: .granted,
    calendar: .granted,
    notifications: .granted
  )
}

@MainActor
private final class PermissionsPanelModel: ObservableObject {
  @Published var microphoneStatus: PermissionStatus = .notDetermined
  @Published var screenRecordingStatus: PermissionStatus = .notDetermined
  @Published var calendarStatus: PermissionStatus = .notDetermined
  @Published var notificationStatus: PermissionStatus = .notDetermined
  @Published private(set) var requestingPermissionIDs: Set<String> = []
  @Published private(set) var calendarRequiresSystemSettings = false
  @Published private(set) var screenRecordingRestartRequired = false

  /// True when every "Required" permission is granted (Mic + Screen
  /// Recording). The onboarding window's Done button gates on this so
  /// the user can't dismiss before fixing the blockers.
  var allRequiredGranted: Bool {
    microphoneStatus == .granted && screenRecordingStatus == .granted
  }

  /// Fires when `requestScreenRecording()` reports access granted but
  /// `screenRecordingStatus()` still returns denied — the macOS quirk
  /// where TCC propagation requires a process restart. AppDelegate
  /// owns the relaunch alert; the model just surfaces the signal.
  var onScreenRecordingRestartRequired: (@MainActor () -> Void)?
  var onPermissionFlowFinished: (@MainActor () -> Void)?

  private let permissions: PermissionsService
  private let autoPoll: Bool
  private let debugStatuses: DebugPermissionStatuses?
  private var refreshTimer: Timer?
  private var didBecomeActiveObserver: NSObjectProtocol?
  private var awaitingExternalPermissionReturn = false
  private var didOpenScreenRecordingSettings = false

  init(
    autoPoll: Bool,
    permissions: PermissionsService = PermissionsService(),
    debugStatuses: DebugPermissionStatuses? = nil
  ) {
    self.autoPoll = autoPoll
    self.permissions = permissions
    self.debugStatuses = debugStatuses
    if let debugStatuses {
      microphoneStatus = debugStatuses.microphone
      screenRecordingStatus = debugStatuses.screenRecording
      calendarStatus = debugStatuses.calendar
      notificationStatus = debugStatuses.notifications
    }
  }

  // No deinit cleanup: Swift 6 forbids reaching the MainActor-isolated
  // `refreshTimer` / `didBecomeActiveObserver` from a nonisolated
  // deinit. The Timer captures `[weak self]` so it auto-no-ops after
  // dealloc; observer leak is bounded by call sites invoking `stop()`
  // (the SwiftUI view's `onDisappear` does this).

  /// Kick off one immediate refresh, then (when `autoPoll`) the 1.5s
  /// poll and the becomes-active observer. The poll cadence matches
  /// what the deprecated popover used; TCC has no change-notification
  /// API for these scopes so polling is the cheap fallback.
  func start() {
    if debugStatuses != nil { return }
    Task { @MainActor [weak self] in
      await self?.refreshStatuses()
    }
    guard autoPoll else { return }
    refreshTimer?.invalidate()
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        await self?.refreshStatuses()
      }
    }
    if didBecomeActiveObserver == nil {
      didBecomeActiveObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          await self?.handleApplicationBecameActive()
        }
      }
    }
  }

  func stop() {
    refreshTimer?.invalidate()
    refreshTimer = nil
    if let token = didBecomeActiveObserver {
      NotificationCenter.default.removeObserver(token)
      didBecomeActiveObserver = nil
    }
  }

  func refreshStatuses() async {
    if let debugStatuses {
      microphoneStatus = debugStatuses.microphone
      screenRecordingStatus = debugStatuses.screenRecording
      calendarStatus = debugStatuses.calendar
      notificationStatus = debugStatuses.notifications
      return
    }
    let probe = DefaultPermissionStatusProbe(permissions: permissions)
    async let mic = probe.microphone()
    async let screen = probe.screenRecording()
    async let cal = probe.calendar()
    async let notif = notificationPermissionStatus()
    microphoneStatus = await mic
    screenRecordingStatus = await screen
    applyCalendarStatus(await cal)
    notificationStatus = await notif
    if screenRecordingStatus == .granted {
      screenRecordingRestartRequired = false
      didOpenScreenRecordingSettings = false
    }
  }

  func isRequesting(_ id: String) -> Bool {
    requestingPermissionIDs.contains(id)
  }

  func requestMicrophone() async {
    await withPermissionRequest("microphone") { [self] in
      _ = await permissions.requestMicrophone()
      await refreshStatuses()
    }
  }

  func requestScreenRecording() async {
    await withPermissionRequest("screenRecording") { [self] in
      awaitingExternalPermissionReturn = true
      let granted = await permissions.requestScreenRecording()
      await refreshStatuses()
      if granted, screenRecordingStatus == .denied {
        screenRecordingRestartRequired = true
        onScreenRecordingRestartRequired?()
      }
    }
  }

  func requestScreenRecordingRestart() {
    onScreenRecordingRestartRequired?()
  }

  func requestCalendar() async {
    await withPermissionRequest("calendar") { [self] in
      let before = calendarStatus
      let status = await permissions.requestCalendar()
      await refreshStatuses()
      if before == .notDetermined, status != .granted, calendarStatus == .notDetermined {
        calendarRequiresSystemSettings = true
        calendarStatus = .denied
      }
    }
  }

  func requestNotifications() async {
    await withPermissionRequest("notifications") { [self] in
      do {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [
          .alert, .sound,
        ])
        notificationStatus = granted ? .granted : .denied
      } catch {
        notificationStatus = .denied
      }
    }
  }

  func openSystemSettings(permissionID: String, pane: String) {
    if permissionID == "screenRecording" {
      _ = CGRequestScreenCaptureAccess()
      didOpenScreenRecordingSettings = true
      awaitingExternalPermissionReturn = true
    }
    if permissionID == "calendar" {
      calendarRequiresSystemSettings = true
      awaitingExternalPermissionReturn = true
    }
    Self.openSystemSettings(pane)
  }

  private func withPermissionRequest(_ id: String, operation: @escaping @MainActor () async -> Void) async {
    requestingPermissionIDs.insert(id)
    defer {
      requestingPermissionIDs.remove(id)
      onPermissionFlowFinished?()
    }
    await operation()
  }

  private func handleApplicationBecameActive() async {
    let shouldRestore = awaitingExternalPermissionReturn
    await refreshStatuses()
    if didOpenScreenRecordingSettings, screenRecordingStatus == .denied {
      screenRecordingRestartRequired = true
    }
    if shouldRestore {
      awaitingExternalPermissionReturn = false
      onPermissionFlowFinished?()
    }
  }

  private func applyCalendarStatus(_ status: PermissionStatus) {
    switch status {
    case .granted, .denied:
      calendarRequiresSystemSettings = false
      calendarStatus = status
    case .notDetermined:
      calendarStatus = calendarRequiresSystemSettings ? .denied : .notDetermined
    }
  }

  private static func openSystemSettings(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
      NSWorkspace.shared.open(url)
    }
  }

  private func notificationPermissionStatus() async -> PermissionStatus {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral: return .granted
    case .denied: return .denied
    case .notDetermined: return .notDetermined
    @unknown default: return .notDetermined
    }
  }
}

/// Shared permissions panel content rendered by both the Settings tab
/// and the standalone Permissions onboarding window. Owns its panel
/// model so each surface has its own polling state. Dynamic per-status
/// buttons: `.notDetermined` → in-app Allow…, `.denied` → deep-link to
/// System Settings, `.granted` → no button (status pill carries it).
struct FidelityPermissionsPanel: View {
  @StateObject private var model: PermissionsPanelModel
  private let title: String
  private let subtitle: String
  private let renderIntro: Bool
  private let showsBypassExplainer: Bool

  private let onRequiredStateChanged: ((Bool) -> Void)?

  init(
    title: String = "Permissions",
    subtitle: String =
      "Grant a few macOS permissions to capture meetings. Audio stays on your Mac. You can change access anytime in System Settings.",
    autoPoll: Bool = false,
    renderIntro: Bool = true,
    showsBypassExplainer: Bool = false,
    onScreenRecordingRestartRequired: (@MainActor () -> Void)? = nil,
    onPermissionRequestFinished: @escaping @MainActor () -> Void = {},
    onRequiredStateChanged: ((Bool) -> Void)? = nil,
    debugStatuses: DebugPermissionStatuses? = nil
  ) {
    self.title = title
    self.subtitle = subtitle
    self.renderIntro = renderIntro
    self.showsBypassExplainer = showsBypassExplainer
    self.onRequiredStateChanged = onRequiredStateChanged
    let panel = PermissionsPanelModel(
      autoPoll: autoPoll,
      debugStatuses: debugStatuses
    )
    panel.onScreenRecordingRestartRequired = onScreenRecordingRestartRequired
    panel.onPermissionFlowFinished = onPermissionRequestFinished
    _model = StateObject(wrappedValue: panel)
  }

  private struct RowSpec: Identifiable {
    let id: String
    let title: String
    let help: String
    let statusKey: KeyPath<PermissionsPanelModel, PermissionStatus>
    let request: @MainActor () async -> Void
    let systemPane: String
  }

  private var requiredRowSpecs: [RowSpec] {
    [
      RowSpec(
        id: "microphone",
        title: "Microphone",
        help: "Records your side of the meeting.",
        statusKey: \.microphoneStatus,
        request: { await model.requestMicrophone() },
        systemPane: "Privacy_Microphone"
      ),
      RowSpec(
        id: "screenRecording",
        title: "System Audio Recording",
        help: "Captures audio from the meeting app. No video.",
        statusKey: \.screenRecordingStatus,
        request: { await model.requestScreenRecording() },
        systemPane: "Privacy_ScreenCapture"
      ),
    ]
  }

  private var recommendedRowSpecs: [RowSpec] {
    [
      RowSpec(
        id: "calendar",
        title: "Calendar",
        help: "Names transcripts and labels speakers.",
        statusKey: \.calendarStatus,
        request: { await model.requestCalendar() },
        systemPane: "Privacy_Calendars"
      ),
      RowSpec(
        id: "notifications",
        title: "Notifications",
        help: "Alerts you when a transcript is ready.",
        statusKey: \.notificationStatus,
        request: { await model.requestNotifications() },
        systemPane: "Privacy_Notifications"
      ),
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if renderIntro {
        FidelityPanelIntro(title: title, subtitle: subtitle)
      }

      permissionsSection(title: "Required", specs: requiredRowSpecs)
        .padding(.bottom, 24)

      permissionsSection(title: "Recommended", specs: recommendedRowSpecs)
        .padding(.bottom, showsBypassExplainer ? 14 : 0)

      if showsBypassExplainer {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "info.circle")
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(FidelitySettings.ink3)
            .padding(.top, 2)
          FidelityHelpText(
            "macOS may occasionally ask Scribe to bypass the system private window picker — say Allow. It's how Scribe captures system audio without picking a window each time."
          )
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
      }
    }
    .task {
      model.start()
    }
    .onDisappear {
      model.stop()
    }
    .onChange(of: model.microphoneStatus) { _, _ in
      onRequiredStateChanged?(model.allRequiredGranted)
    }
    .onChange(of: model.screenRecordingStatus) { _, _ in
      onRequiredStateChanged?(model.allRequiredGranted)
    }
  }

  // ForEach (vs an inline TupleView) is the defensive choice: tuple
  // builders are fine up to 10 children, but a previous inline version
  // rendered only the first rows in some builds (suspected first-paint
  // race against the @StateObject's async refresh). ForEach with stable
  // IDs forces SwiftUI to diff per-row instead of treating the whole
  // section as one opaque tuple.
  @ViewBuilder
  private func permissionsSection(title: String, specs: [RowSpec]) -> some View {
    FidelitySection(title: title) {
      ForEach(Array(specs.enumerated()), id: \.element.id) { index, spec in
        if index > 0 {
          FidelityRowDivider()
        }
        let status = model[keyPath: spec.statusKey]
        FidelityPermissionRow(
          title: spec.title,
          status: status,
          help: rowHelp(for: spec, status: status),
          action: rowAction(for: spec, status: status)
        )
      }
    }
  }

  private func rowAction(for spec: RowSpec, status: PermissionStatus) -> FidelityPermissionAction? {
    if model.isRequesting(spec.id) {
      return .secondary("Requesting…", isEnabled: false) {}
    }
    if spec.id == "screenRecording", model.screenRecordingRestartRequired {
      return .secondary("Restart Scribe", isEnabled: true) {
        model.requestScreenRecordingRestart()
      }
    }
    switch status {
    case .granted:
      return nil
    case .notDetermined:
      return .secondary("Allow", isEnabled: true) {
        Task { @MainActor in await spec.request() }
      }
    case .denied:
      return .systemSettings {
        model.openSystemSettings(permissionID: spec.id, pane: spec.systemPane)
      }
    }
  }

  private func rowHelp(for spec: RowSpec, status: PermissionStatus) -> String {
    if model.isRequesting(spec.id) {
      return "Waiting for the macOS permission flow to finish."
    }
    if spec.id == "screenRecording", model.screenRecordingRestartRequired {
      return "If you turned this on in System Settings and Scribe still says Denied, macOS requires a Scribe restart."
    }
    if spec.id == "calendar", model.calendarRequiresSystemSettings {
      return "macOS did not start the Calendar prompt. Open System Settings and grant Scribe full calendar access."
    }
    if spec.id == "screenRecording", status == .denied {
      return "Open Screen & System Audio Recording, turn Scribe on, then return here."
    }
    return spec.help
  }

}

private enum FidelityPermissionAction {
  case systemSettings(@MainActor () -> Void)
  case secondary(String, isEnabled: Bool = true, @MainActor () -> Void)

  var title: String {
    switch self {
    case .systemSettings:
      return "Open in System Settings"
    case .secondary(let title, _, _):
      return title
    }
  }

  var isEnabled: Bool {
    switch self {
    case .systemSettings:
      return true
    case .secondary(_, let isEnabled, _):
      return isEnabled
    }
  }

  var isSystemSettings: Bool {
    if case .systemSettings = self { return true }
    return false
  }

  @MainActor
  func callAsFunction() {
    guard isEnabled else { return }
    switch self {
    case .systemSettings(let action), .secondary(_, _, let action):
      action()
    }
  }
}

private struct FidelityPermissionRow: View {
  let title: String
  let status: PermissionStatus
  let help: String
  /// `nil` when no action is appropriate (e.g., status == .granted).
  /// The row still renders title, status pill, and description; the
  /// button column collapses so the row stays balanced.
  let action: FidelityPermissionAction?

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Circle()
        .fill(status.fidelityColor)
        .frame(width: 8, height: 8)
        .padding(.top, 7)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
          Text(title)
            .font(FidelitySettings.rowFont.weight(.medium))
            .foregroundStyle(FidelitySettings.ink)
            .tracking(-0.08)
          Text(status.fidelityLabel)
            .font(SwiftUI.Font.custom(FidelitySettings.font, size: 11.5).weight(.medium))
            .foregroundStyle(status.fidelityColor)
        }
        FidelityHelpText(help)
      }
      Spacer(minLength: 12)
      if let action {
        FidelityPermissionButton(action: action)
          .padding(.top, 2)
      } else if status == .granted {
        FidelityGrantedIndicator()
          .padding(.top, 2)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .contentShape(Rectangle())
  }
}

private struct FidelityGrantedIndicator: View {
  var body: some View {
    HStack(spacing: 4) {
      LucideIcon(glyph: .check)
        .frame(width: 12, height: 12)
        .foregroundStyle(FidelitySettings.green)
      Text("Granted")
        .font(SwiftUI.Font.custom(FidelitySettings.font, size: 12.5).weight(.medium))
        .foregroundStyle(FidelitySettings.ink3)
    }
    .frame(height: 28)
    .padding(.horizontal, 8)
  }
}

private struct FidelityPermissionButton: View {
  let action: FidelityPermissionAction

  var body: some View {
    Button {
      action()
    } label: {
      HStack(spacing: 4) {
        Text(action.title)
          .font(
            SwiftUI.Font.custom(FidelitySettings.font, size: 12.5)
              .weight(action.isSystemSettings ? .medium : .semibold))
        if action.isSystemSettings {
          LucideIcon(glyph: .arrowUpRight)
            .frame(width: 10.5, height: 10.5)
            .opacity(0.58)
        }
      }
      .foregroundStyle(
        action.isSystemSettings ? FidelitySettings.ink2 : FidelitySettings.inkInverse
      )
      .padding(.horizontal, action.isSystemSettings ? 8 : 14)
      .frame(height: 28)
      .background(buttonBackground)
      .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(!action.isEnabled)
    .opacity(action.isEnabled ? 1 : 0.62)
    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  @ViewBuilder
  private var buttonBackground: some View {
    if action.isSystemSettings {
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill(SwiftUI.Color.clear)
    } else {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(FidelitySettings.ink)
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(SwiftUI.Color.black.opacity(0.08), lineWidth: 1)
        )
    }
  }
}

extension PermissionStatus {
  var fidelityLabel: String {
    switch self {
    case .granted: return "Granted"
    case .denied: return "Denied"
    case .notDetermined: return "Not asked"
    }
  }

  var fidelityColor: SwiftUI.Color {
    switch self {
    case .granted: return FidelitySettings.green
    case .denied: return FidelitySettings.amber
    case .notDetermined: return FidelitySettings.ink3
    }
  }
}
