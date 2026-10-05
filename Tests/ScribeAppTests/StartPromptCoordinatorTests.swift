import AppKit
@testable import ScribeAppLogic
import TranscriberCore
import UserNotifications
import XCTest

@MainActor
final class StartPromptCoordinatorTests: XCTestCase {
    private let app = MeetingApps.allowlist[0]

    func testResolvedStartPromptRemovesNotificationWhoseSubmissionCompletesLate() async throws {
        let notifications = SuspendedNotifications()
        let coordinator = makeCoordinator(notifications)
        let prompt = Task { await coordinator.prompt(for: app) }
        try await eventually { notifications.requests.count == 1 }
        let identifier = notifications.requests[0].identifier

        coordinator.chooseStartFromRecovery()
        let choice = await prompt.value
        XCTAssertEqual(choice, .start)
        XCTAssertFalse(coordinator.hasActivePrompt)
        XCTAssertTrue(notifications.removed.contains(identifier))
        notifications.complete(identifier)
        try await eventually { notifications.removed.filter { $0 == identifier }.count == 2 }
        XCTAssertTrue(notifications.delivered.isEmpty)
    }

    func testReplacementStartPromptKeepsItsOwnNotificationAfterOldSubmissionCompletes() async throws {
        let notifications = SuspendedNotifications()
        let coordinator = makeCoordinator(notifications)
        let first = Task { await coordinator.prompt(for: app) }
        try await eventually { notifications.requests.count == 1 }
        let oldID = notifications.requests[0].identifier
        coordinator.chooseNotNowFromRecovery()
        _ = await first.value

        let replacement = Task { await coordinator.prompt(for: app) }
        try await eventually { notifications.requests.count == 2 }
        let replacementID = notifications.requests[1].identifier
        XCTAssertNotEqual(oldID, replacementID)
        notifications.complete(replacementID)
        try await eventually { notifications.delivered.contains(replacementID) }
        notifications.complete(oldID)
        try await eventually { notifications.removed.filter { $0 == oldID }.count == 2 }
        XCTAssertEqual(notifications.delivered, [replacementID])
        XCTAssertTrue(coordinator.hasActivePrompt)
        coordinator.chooseNotNowFromRecovery()
        _ = await replacement.value
    }

    func testClearedEndPromptRemovesNotificationWhoseSubmissionCompletesLate() async throws {
        let notifications = SuspendedNotifications()
        let coordinator = makeCoordinator(notifications)
        let posting = Task {
            await coordinator.postEndPromptNotificationIfPossible(
                promptID: "end", generation: 1, reason: .callEnded, secondsRemaining: 10,
                onKeep: { _ in XCTFail("Unexpected action") }, onStopNow: { _ in XCTFail("Unexpected action") }
            )
        }
        try await eventually { notifications.requests.count == 1 }
        let identifier = notifications.requests[0].identifier
        coordinator.clearEndPromptNotification(promptID: "end")
        notifications.complete(identifier)
        let posted = await posting.value
        XCTAssertFalse(posted)
        XCTAssertTrue(notifications.delivered.isEmpty)
        XCTAssertEqual(notifications.removed.filter { $0 == identifier }.count, 2)
    }

    func testReplacementEndPromptSurvivesOldSubmissionAndRejectsOldActions() async throws {
        let notifications = SuspendedNotifications()
        let coordinator = makeCoordinator(notifications)
        var generations: [Int] = []
        let first = Task {
            await coordinator.postEndPromptNotificationIfPossible(
                promptID: "end", generation: 1, reason: .callEnded, secondsRemaining: 10,
                onKeep: { generations.append($0) }, onStopNow: { generations.append($0) }
            )
        }
        try await eventually { notifications.requests.count == 1 }
        let replacement = Task {
            await coordinator.postEndPromptNotificationIfPossible(
                promptID: "end", generation: 2, reason: .callEnded, secondsRemaining: 8,
                onKeep: { generations.append($0) }, onStopNow: { generations.append($0) }
            )
        }
        try await eventually { notifications.requests.count == 2 }
        let oldID = notifications.requests[0].identifier
        let newID = notifications.requests[1].identifier
        notifications.complete(newID)
        let replacementPosted = await replacement.value
        XCTAssertTrue(replacementPosted)
        notifications.complete(oldID)
        let firstPosted = await first.value
        XCTAssertFalse(firstPosted)
        XCTAssertEqual(notifications.delivered, [newID])
        await coordinator.resolveEndPromptNotification(promptID: "end", generation: 1, actionID: "scribe.end-prompt.action.stop-now")
        XCTAssertTrue(generations.isEmpty)
        await coordinator.resolveEndPromptNotification(promptID: "end", generation: 2, actionID: "scribe.end-prompt.action.keep-recording")
        await coordinator.resolveEndPromptNotification(promptID: "end", generation: 2, actionID: "scribe.end-prompt.action.stop-now")
        XCTAssertEqual(generations, [2])
        XCTAssertTrue(notifications.delivered.isEmpty)
    }

    func testDismissedModalCoalescesAwaitersAndRetainsRecovery() async throws {
        let notifications = SuspendedNotifications()
        notifications.suspend = false
        var presentations = 0
        let coordinator = StartPromptCoordinator(notifications: notifications, runModal: { _, _, _ in
            presentations += 1
            return .dismissed
        })
        let first = Task { await coordinator.prompt(for: app) }
        try await eventually { notifications.requests.count == 1 }
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return await coordinator.prompt(for: app)
        }
        try await eventually { secondStarted }
        XCTAssertTrue(coordinator.hasActivePrompt)
        XCTAssertEqual(presentations, 1)
        coordinator.chooseSuppressAppFromRecovery()
        let choices = await [first.value, second.value]
        XCTAssertEqual(choices, [.notAMeeting, .notAMeeting])
        XCTAssertTrue(notifications.delivered.isEmpty)
        XCTAssertFalse(coordinator.hasActivePrompt)
    }

    func testEndedCandidateOnlyExpiresMatchingPrompt() async throws {
        let notifications = SuspendedNotifications()
        notifications.suspend = false
        let coordinator = makeCoordinator(notifications)
        let candidate = DetectionCandidate(app: app, triggerIdentity: "calendar:event-1:occurrence-1")
        let prompt = Task { await coordinator.prompt(for: candidate) }
        try await eventually { notifications.requests.count == 1 }
        coordinator.expireActivePrompt(for: DetectionCandidate(app: app, triggerIdentity: "calendar:event-2:occurrence-2"))
        XCTAssertTrue(coordinator.hasActivePrompt)
        coordinator.expireActivePrompt(for: candidate)
        let choice = await prompt.value
        XCTAssertEqual(choice, .skipForNow)
        XCTAssertTrue(notifications.delivered.isEmpty)
    }

    func testAuthorizationIsReadForEachPromptAfterGrantAndRevocation() async {
        let notifications = SuspendedNotifications()
        notifications.suspend = false
        let coordinator = makeCoordinator(notifications)
        var outcomes: [Bool] = []
        for allowed in [false, true, false, true] {
            notifications.authorized = allowed
            outcomes.append(await coordinator.postEndPromptNotificationIfPossible(
                promptID: "end", generation: 1, reason: .callEnded, secondsRemaining: 10,
                onKeep: { _ in }, onStopNow: { _ in }
            ))
            coordinator.clearEndPromptNotification(promptID: "end")
        }
        XCTAssertEqual(outcomes, [false, true, false, true])
        XCTAssertEqual(notifications.authorizationQueries, 4)
        XCTAssertEqual(notifications.requests.count, 2)
        XCTAssertTrue(notifications.delivered.isEmpty)
    }

    private func makeCoordinator(_ notifications: SuspendedNotifications) -> StartPromptCoordinator {
        StartPromptCoordinator(notifications: notifications, runModal: { _, _, _ in .dismissed })
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for notification state")
                throw WaitError.timedOut
            }
            await Task.yield()
        }
    }

    private enum WaitError: Error { case timedOut }
}

@MainActor
final class SuspendedNotifications: PromptNotificationClient {
    var authorized = true
    var suspend = true
    var authorizationQueries = 0
    var requests: [UNNotificationRequest] = []
    var delivered: Set<String> = []
    var removed: [String] = []
    private var submissions: [String: CheckedContinuation<Void, Never>] = [:]

    func setDelegate(_ delegate: any UNUserNotificationCenterDelegate) {}
    func setCategories(_ categories: Set<UNNotificationCategory>) {}

    func isAuthorized() async -> Bool {
        authorizationQueries += 1
        return authorized
    }

    func add(_ request: UNNotificationRequest) async throws {
        requests.append(request)
        if suspend {
            await withCheckedContinuation { submissions[request.identifier] = $0 }
        }
        delivered.insert(request.identifier)
    }

    func complete(_ identifier: String) {
        submissions.removeValue(forKey: identifier)?.resume()
    }

    func remove(identifiers: [String]) {
        removed.append(contentsOf: identifiers)
        delivered.subtract(identifiers)
    }
}
