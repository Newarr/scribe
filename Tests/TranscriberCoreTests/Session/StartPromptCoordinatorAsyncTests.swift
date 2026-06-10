@testable import TranscriberCore
import XCTest

final class StartPromptCoordinatorAsyncTests: XCTestCase {
  func testDuplicateStartPromptsCoalesceAndResumeAllAwaiters() async throws {
    let presenter = PromptPresenterProbe()
    let notifications = NotificationProbe()
    let coordinator = PromptNotificationCoordinatorCore(
      presentPrompt: presenter.present,
      postStartNotification: notifications.postStart,
      authorizationProvider: { .authorized }
    )
    let request = PromptNotificationCoordinatorCore.StartPromptRequest(
      identifier: "calendar:event-1:2026-05-20T10:00:00Z",
      appDisplayName: "Zoom",
      eventTitle: "Acme Weekly"
    )

    async let first = coordinator.prompt(for: request)
    async let second = coordinator.prompt(for: request)

    try await eventually("duplicate prompt coalesced into one pending entry") {
      let pendingCount = await coordinator.pendingStartCount
      let presentedCount = await presenter.presentedCount
      return pendingCount == 1 && presentedCount == 1
    }
    let dismissedPendingCount = await coordinator.pendingStartCount
    XCTAssertEqual(dismissedPendingCount, 1)
    let hasActivePrompt = await coordinator.hasActivePrompt
    XCTAssertTrue(hasActivePrompt)
    let startNotificationCount = await notifications.startRequestCount
    XCTAssertEqual(startNotificationCount, 1)

    await coordinator.chooseStartFromRecovery(identifier: request.identifier)
    await presenter.dismissAll()

    let choices = await [first, second]
    XCTAssertEqual(choices, [.start, .start])
    let finalPendingCount = await coordinator.pendingStartCount
    XCTAssertEqual(finalPendingCount, 0)
    let finalHasActivePrompt = await coordinator.hasActivePrompt
    XCTAssertFalse(finalHasActivePrompt)
  }

  func testNotificationAuthorizationIsRequeriedAndHonorsRevocationAndGrantChanges() async throws {
    let authorization = AuthorizationProbe(statuses: [.authorized, .denied, .authorized, .denied])
    let notifications = NotificationProbe()
    let coordinator = PromptNotificationCoordinatorCore(
      presentPrompt: { _ in .dismissed },
      postStartNotification: notifications.postStart,
      authorizationProvider: authorization.next
    )
    let request = PromptNotificationCoordinatorCore.StartPromptRequest(
      identifier: "app:us.zoom.xos",
      appDisplayName: "Zoom"
    )

    async let promptChoice = coordinator.prompt(for: request)
    try await eventually("prompt remains pending after modal dismissal") {
      await coordinator.isModalDismissedAndRetryable(identifier: request.identifier)
    }

    let denied = await coordinator.postStartNotificationIfPossible(
      .init(
        promptID: request.identifier,
        kind: .reminder,
        appDisplayName: "Zoom",
        eventTitle: nil
      ))
    let granted = await coordinator.postStartNotificationIfPossible(
      .init(
        promptID: request.identifier,
        kind: .reminder,
        appDisplayName: "Zoom",
        eventTitle: nil
      ))
    let revoked = await coordinator.postStartNotificationIfPossible(
      .init(
        promptID: request.identifier,
        kind: .finalReminder,
        appDisplayName: "Zoom",
        eventTitle: nil
      ))

    XCTAssertFalse(denied)
    XCTAssertTrue(granted)
    XCTAssertFalse(revoked)
    let authorizationCallCount = await authorization.callCount
    XCTAssertEqual(authorizationCallCount, 4)
    let postedKinds = await notifications.startRequestKinds
    XCTAssertEqual(postedKinds, [.backup, .reminder])

    await coordinator.chooseNotNowFromRecovery(identifier: request.identifier)
    _ = await promptChoice
  }

  func testStaleGenerationEndPromptActionsDoNotAffectCurrentSession() async {
    let callbacks = EndPromptCallbackProbe()
    let coordinator = PromptNotificationCoordinatorCore(
      presentPrompt: { _ in .dismissed },
      postEndNotification: { _ in },
      authorizationProvider: { .authorized }
    )

    let firstPosted = await coordinator.postEndPromptNotificationIfPossible(
      promptID: "end-prompt",
      generation: 1,
      secondsRemaining: 10,
      onAction: callbacks.handle
    )
    let secondPosted = await coordinator.postEndPromptNotificationIfPossible(
      promptID: "end-prompt",
      generation: 2,
      secondsRemaining: 8,
      onAction: callbacks.handle
    )

    XCTAssertTrue(firstPosted)
    XCTAssertTrue(secondPosted)

    await coordinator.resolveEndPromptNotification(
      promptID: "end-prompt",
      generation: 1,
      action: .stopNow
    )
    let staleCallbacks = await callbacks.callbacks
    XCTAssertEqual(staleCallbacks, [])

    await coordinator.resolveEndPromptNotification(
      promptID: "end-prompt",
      generation: 2,
      action: .keepRecording
    )
    let acceptedCallbacks = await callbacks.callbacks
    XCTAssertEqual(
      acceptedCallbacks,
      [
        .init(promptID: "end-prompt", generation: 2, action: .keepRecording)
      ])

    await coordinator.resolveEndPromptNotification(
      promptID: "end-prompt",
      generation: 2,
      action: .stopNow
    )
    let callbackCount = await callbacks.callbackCount
    XCTAssertEqual(callbackCount, 1)
  }

  func testModalDismissalLeavesPromptRetryableWithoutOrphanedContinuations() async throws {
    let coordinator = PromptNotificationCoordinatorCore(
      presentPrompt: { _ in .dismissed },
      postStartNotification: { _ in },
      authorizationProvider: { .authorized }
    )
    let request = PromptNotificationCoordinatorCore.StartPromptRequest(
      identifier: "app:com.microsoft.teams2",
      appDisplayName: "Microsoft Teams"
    )

    async let first = coordinator.prompt(for: request)
    try await eventually("dismissed modal remains pending and retryable") {
      await coordinator.isModalDismissedAndRetryable(identifier: request.identifier)
    }
    let dismissedPendingCount = await coordinator.pendingStartCount
    XCTAssertEqual(dismissedPendingCount, 1)
    let dismissedHasActivePrompt = await coordinator.hasActivePrompt
    XCTAssertTrue(dismissedHasActivePrompt)

    async let second = coordinator.prompt(for: request)
    try await eventually("duplicate awaiter joined dismissed prompt") {
      await coordinator.pendingAwaiterCount(identifier: request.identifier) == 2
    }

    await coordinator.chooseSuppressAppFromRecovery(identifier: request.identifier)

    let choices = await [first, second]
    XCTAssertEqual(choices, [.notAMeeting, .notAMeeting])
    let recoveredPendingCount = await coordinator.pendingStartCount
    let recoveredHasActivePrompt = await coordinator.hasActivePrompt
    XCTAssertEqual(recoveredPendingCount, 0)
    XCTAssertFalse(recoveredHasActivePrompt)
  }

  private func eventually(
    _ description: String,
    timeout: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @escaping () async -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for \(description)", file: file, line: line)
  }
}

private actor PromptPresenterProbe {
  private(set) var presented: [PromptNotificationCoordinatorCore.StartPromptRequest] = []
  private var continuations:
    [CheckedContinuation<PromptNotificationCoordinatorCore.ModalDecision, Never>] = []

  var presentedCount: Int { presented.count }

  func present(_ request: PromptNotificationCoordinatorCore.StartPromptRequest) async
    -> PromptNotificationCoordinatorCore.ModalDecision
  {
    presented.append(request)
    return await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func dismissAll() {
    let pending = continuations
    continuations.removeAll(keepingCapacity: false)
    for continuation in pending {
      continuation.resume(returning: .dismissed)
    }
  }
}

private actor NotificationProbe {
  private(set) var startRequests: [PromptNotificationCoordinatorCore.StartNotificationRequest] = []

  var startRequestCount: Int { startRequests.count }
  var startRequestKinds: [PromptNotificationCoordinatorCore.StartNotificationKind] {
    startRequests.map(\.kind)
  }

  func postStart(_ request: PromptNotificationCoordinatorCore.StartNotificationRequest) async throws
  {
    startRequests.append(request)
  }
}

private actor AuthorizationProbe {
  private var statuses: [PromptNotificationCoordinatorCore.NotificationAuthorization]
  private(set) var callCount = 0

  init(statuses: [PromptNotificationCoordinatorCore.NotificationAuthorization]) {
    self.statuses = statuses
  }

  func next() async -> PromptNotificationCoordinatorCore.NotificationAuthorization {
    callCount += 1
    if statuses.isEmpty { return .denied }
    return statuses.removeFirst()
  }
}

private actor EndPromptCallbackProbe {
  private(set) var callbacks: [PromptNotificationCoordinatorCore.EndPromptCallback] = []

  var callbackCount: Int { callbacks.count }

  func handle(_ callback: PromptNotificationCoordinatorCore.EndPromptCallback) async {
    callbacks.append(callback)
  }
}
