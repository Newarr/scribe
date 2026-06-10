import Foundation

/// Testable prompt/notification state machine for the Scribe app shell.
///
/// The AppKit/UNUserNotificationCenter coordinator owns real windows and system
/// notifications, while this core seam captures the async invariants that must
/// not regress: duplicate start prompts share all awaiters, authorization is
/// re-read for each notification attempt, notification actions are generation
/// guarded, and dismissed modals leave recovery actions retryable.
actor PromptNotificationCoordinatorCore {
  enum StartChoice: Sendable, Equatable {
    case start
    case notAMeeting
    case skipForNow
  }

  enum ModalDecision: Sendable, Equatable {
    case primary
    case secondary
    case dismissed
  }

  enum NotificationAuthorization: Sendable, Equatable {
    case authorized
    case denied
    case notDetermined(grantedOnRequest: Bool)
  }

  enum StartNotificationKind: Sendable, Equatable {
    case backup
    case reminder
    case finalReminder
  }

  enum EndPromptAction: Sendable, Equatable {
    case keepRecording
    case stopNow
    case dismissed
    case defaultAction
  }

  struct StartPromptRequest: Sendable, Equatable {
    let identifier: String
    let appDisplayName: String
    let eventTitle: String?

    init(identifier: String, appDisplayName: String, eventTitle: String? = nil) {
      self.identifier = identifier
      self.appDisplayName = appDisplayName
      self.eventTitle = eventTitle
    }
  }

  struct StartNotificationRequest: Sendable, Equatable {
    let promptID: String
    let kind: StartNotificationKind
    let appDisplayName: String
    let eventTitle: String?

    init(
      promptID: String, kind: StartNotificationKind, appDisplayName: String, eventTitle: String?
    ) {
      self.promptID = promptID
      self.kind = kind
      self.appDisplayName = appDisplayName
      self.eventTitle = eventTitle
    }
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

  typealias PromptPresenter = @Sendable (StartPromptRequest) async -> ModalDecision
  typealias StartNotificationPoster =
    @Sendable (StartNotificationRequest) async throws -> Void
  typealias EndNotificationPoster = @Sendable (EndNotificationRequest) async throws -> Void
  typealias AuthorizationProvider = @Sendable () async -> NotificationAuthorization
  typealias EndPromptCallbackHandler = @Sendable (EndPromptCallback) async -> Void

  private final class PendingStart: @unchecked Sendable {
    let request: StartPromptRequest
    var continuations: [CheckedContinuation<StartChoice, Never>]
    var modalDismissed = false

    init(request: StartPromptRequest, continuation: CheckedContinuation<StartChoice, Never>) {
      self.request = request
      self.continuations = [continuation]
    }

    func append(_ continuation: CheckedContinuation<StartChoice, Never>) {
      continuations.append(continuation)
    }

    func resumeAll(returning choice: StartChoice) {
      let awaiters = continuations
      continuations.removeAll(keepingCapacity: false)
      for continuation in awaiters {
        continuation.resume(returning: choice)
      }
    }
  }

  private struct PendingEnd: Sendable {
    let promptID: String
    let generation: Int
    let onAction: EndPromptCallbackHandler
  }

  private let presentPrompt: PromptPresenter
  private let postStartNotification: StartNotificationPoster
  private let postEndNotification: EndNotificationPoster
  private let authorizationProvider: AuthorizationProvider

  private var pendingStarts: [String: PendingStart] = [:]
  private var activePromptIdentifier: String?
  private var pendingEnds: [String: PendingEnd] = [:]

  init(
    presentPrompt: @escaping PromptPresenter,
    postStartNotification: @escaping StartNotificationPoster = { _ in },
    postEndNotification: @escaping EndNotificationPoster = { _ in },
    authorizationProvider: @escaping AuthorizationProvider = { .authorized }
  ) {
    self.presentPrompt = presentPrompt
    self.postStartNotification = postStartNotification
    self.postEndNotification = postEndNotification
    self.authorizationProvider = authorizationProvider
  }

  var hasActivePrompt: Bool { activePromptIdentifier != nil }

  var pendingStartCount: Int { pendingStarts.count }

  func pendingAwaiterCount(identifier: String) -> Int {
    pendingStarts[identifier]?.continuations.count ?? 0
  }

  func prompt(for request: StartPromptRequest) async -> StartChoice {
    await withCheckedContinuation { continuation in
      if let pending = pendingStarts[request.identifier] {
        pending.append(continuation)
        activePromptIdentifier = request.identifier
        return
      }

      pendingStarts[request.identifier] = PendingStart(request: request, continuation: continuation)
      activePromptIdentifier = request.identifier

      Task { [weak self] in
        guard let self else { return }
        _ = await self.postStartNotificationIfPossible(
          StartNotificationRequest(
            promptID: request.identifier,
            kind: .backup,
            appDisplayName: request.appDisplayName,
            eventTitle: request.eventTitle
          )
        )
      }
      Task { [weak self] in
        guard let self else { return }
        let decision = await self.presentPrompt(request)
        await self.resolveModalDecision(decision, identifier: request.identifier)
      }
    }
  }

  @discardableResult
  func postStartNotificationIfPossible(_ request: StartNotificationRequest) async -> Bool {
    guard await ensureAuthorization() else { return false }
    guard pendingStarts[request.promptID] != nil else { return false }
    do {
      try await postStartNotification(request)
      return true
    } catch {
      return false
    }
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

  func chooseStartFromRecovery(identifier: String? = nil) {
    resolve(identifier: identifier ?? activePromptIdentifier, with: .start)
  }

  func chooseNotNowFromRecovery(identifier: String? = nil) {
    resolve(identifier: identifier ?? activePromptIdentifier, with: .skipForNow)
  }

  func chooseSuppressAppFromRecovery(identifier: String? = nil) {
    resolve(identifier: identifier ?? activePromptIdentifier, with: .notAMeeting)
  }

  func isModalDismissedAndRetryable(identifier: String) -> Bool {
    pendingStarts[identifier]?.modalDismissed == true
  }

  private func resolveModalDecision(_ decision: ModalDecision, identifier: String) {
    switch decision {
    case .primary:
      resolve(identifier: identifier, with: .start)
    case .secondary:
      resolve(identifier: identifier, with: .skipForNow)
    case .dismissed:
      pendingStarts[identifier]?.modalDismissed = true
    }
  }

  private func resolve(identifier: String?, with choice: StartChoice) {
    guard let identifier, let pending = pendingStarts.removeValue(forKey: identifier) else {
      return
    }
    if activePromptIdentifier == identifier {
      activePromptIdentifier = nil
    }
    pending.resumeAll(returning: choice)
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
