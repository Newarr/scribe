import Foundation

/// Testable end-prompt notification state machine for the Scribe app
/// shell. The pre-call start-prompt half was deleted with the
/// auto-record cutover (plans/auto-record.md); what remains captures
/// the async invariants of the EndGuard stop-prompt notification
/// channel: authorization is re-read for each attempt, and actions are
/// generation-guarded so a stale tap cannot stop the wrong session.
actor PromptNotificationCoordinatorCore {
  enum NotificationAuthorization: Sendable, Equatable {
    case authorized
    case denied
    case notDetermined(grantedOnRequest: Bool)
  }

  enum EndPromptAction: Sendable, Equatable {
    case keepRecording
    case stopNow
    case dismissed
    case defaultAction
  }

  struct EndNotificationRequest: Sendable, Equatable {
    let promptID: String
    let generation: Int
    let secondsRemaining: Int

    init(promptID: String, generation: Int, secondsRemaining: Int) {
      self.promptID = promptID
      self.generation = generation
      self.secondsRemaining = secondsRemaining
    }
  }

  struct EndPromptCallback: Sendable, Equatable {
    let promptID: String
    let generation: Int
    let action: EndPromptAction

    init(promptID: String, generation: Int, action: EndPromptAction) {
      self.promptID = promptID
      self.generation = generation
      self.action = action
    }
  }

  typealias EndNotificationPoster = @Sendable (EndNotificationRequest) async throws -> Void
  typealias AuthorizationProvider = @Sendable () async -> NotificationAuthorization
  typealias EndPromptCallbackHandler = @Sendable (EndPromptCallback) async -> Void

  private struct PendingEnd: Sendable {
    let promptID: String
    let generation: Int
    let onAction: EndPromptCallbackHandler
  }

  private let postEndNotification: EndNotificationPoster
  private let authorizationProvider: AuthorizationProvider
  private var pendingEnds: [String: PendingEnd] = [:]

  init(
    postEndNotification: @escaping EndNotificationPoster = { _ in },
    authorizationProvider: @escaping AuthorizationProvider = { .authorized }
  ) {
    self.postEndNotification = postEndNotification
    self.authorizationProvider = authorizationProvider
  }

  @discardableResult
  func postEndPromptNotificationIfPossible(
    promptID: String,
    generation: Int,
    secondsRemaining: Int,
    onAction: @escaping EndPromptCallbackHandler
  ) async -> Bool {
    pendingEnds[promptID] = PendingEnd(
      promptID: promptID,
      generation: generation,
      onAction: onAction
    )
    guard await ensureAuthorization() else { return false }
    guard pendingEnds[promptID]?.generation == generation else { return false }
    do {
      try await postEndNotification(
        EndNotificationRequest(
          promptID: promptID,
          generation: generation,
          secondsRemaining: secondsRemaining
        ))
      return true
    } catch {
      return false
    }
  }

  func resolveEndPromptNotification(
    promptID: String,
    generation: Int?,
    action: EndPromptAction
  ) async {
    guard let pending = pendingEnds[promptID], generation == pending.generation else { return }
    switch action {
    case .keepRecording, .stopNow:
      pendingEnds.removeValue(forKey: promptID)
      await pending.onAction(
        EndPromptCallback(
          promptID: promptID,
          generation: pending.generation,
          action: action
        ))
    case .dismissed:
      return
    case .defaultAction:
      return
    }
  }

  private func ensureAuthorization() async -> Bool {
    switch await authorizationProvider() {
    case .authorized:
      return true
    case .denied:
      return false
    case .notDetermined(let grantedOnRequest):
      return grantedOnRequest
    }
  }
}
