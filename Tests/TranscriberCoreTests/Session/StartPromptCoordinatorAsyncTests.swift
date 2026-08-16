@testable import TranscriberCore
import XCTest

/// End-prompt notification async invariants. The pre-call start-prompt
/// machinery this suite used to cover was removed with the auto-record
/// cutover (plans/auto-record.md); only the EndGuard stop-prompt
/// notification channel remains.
final class StartPromptCoordinatorAsyncTests: XCTestCase {
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
}

private actor EndPromptCallbackProbe {
  private(set) var callbacks: [PromptNotificationCoordinatorCore.EndPromptCallback] = []

  var callbackCount: Int { callbacks.count }

  func handle(_ callback: PromptNotificationCoordinatorCore.EndPromptCallback) async {
    callbacks.append(callback)
  }
}
