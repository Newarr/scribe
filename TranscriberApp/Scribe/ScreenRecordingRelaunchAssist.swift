import Foundation

@MainActor
enum ScreenRecordingRelaunchAssist {
  private static let defaultsKey = "ScreenRecordingPermissionFlowRelaunchAssistArmedAt"
  private static let maxAge: TimeInterval = 10 * 60

  static func arm(now: Date = Date()) {
    UserDefaults.standard.set(now.timeIntervalSinceReferenceDate, forKey: defaultsKey)
  }

  static func disarm() {
    UserDefaults.standard.removeObject(forKey: defaultsKey)
  }

  static func isArmed(now: Date = Date()) -> Bool {
    let armedAt = UserDefaults.standard.double(forKey: defaultsKey)
    guard armedAt > 0 else { return false }
    if now.timeIntervalSinceReferenceDate - armedAt <= maxAge {
      return true
    }
    disarm()
    return false
  }
}
