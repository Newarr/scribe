import Foundation

@MainActor
final class TerminationCoordinator {
  private(set) var hasStarted = false
  private var drainTask: Task<Void, Never>?
  private var deadlineTask: Task<Void, Never>?
  private var completion: (() -> Void)?

  func start(
    drain: @escaping @MainActor () async -> Void,
    waitForDeadline: @escaping @Sendable () async throws -> Void = {
      try await Task.sleep(for: .seconds(10))
    },
    completion: @escaping @MainActor () -> Void
  ) {
    guard !hasStarted else { return }
    hasStarted = true
    self.completion = completion
    drainTask = Task { [weak self] in
      await drain()
      self?.finish()
    }
    deadlineTask = Task { [weak self] in
      do {
        try await waitForDeadline()
        self?.finish()
      } catch {}
    }
  }

  private func finish() {
    guard let completion else { return }
    self.completion = nil
    drainTask?.cancel()
    deadlineTask?.cancel()
    drainTask = nil
    deadlineTask = nil
    completion()
  }
}
