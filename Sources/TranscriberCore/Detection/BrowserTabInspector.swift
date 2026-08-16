import Foundation

/// Three-way result of reading a browser's active tab. `unreadable`
/// (Firefox, timeout, script error, missing automation grant) is the
/// only outcome that may take the calendar-plus-mic fallback: an
/// inspected non-meeting tab is a definitive no.
public enum TabInspectionResult: Sendable, Equatable {
    case meeting
    case notMeeting
    case unreadable
}

/// Seam `DetectionEngine` uses to gate browser candidates. Production
/// is `BrowserTabInspector`; tests inject stubs.
public protocol BrowserTabInspecting: Sendable {
    func inspectActiveTab(bundleID: String) async -> TabInspectionResult
}

/// Answers one question per browser candidate: does the active tab match
/// a meeting domain? Reads the tab with the dialect named on the
/// `MeetingApp` allowlist entry (Safari vs Chromium AppleScript); a
/// `.none` dialect returns `.unreadable` without running anything.
///
/// Every inspection runs under a hard timeout. A hanging AppleEvent is
/// cancelled, never abandoned: the osascript process is terminated on
/// cancellation, so processes do not leak and a dead browser channel
/// never stalls the detection dwell.
public struct BrowserTabInspector: Sendable {
    /// Runs an AppleScript source and returns its stdout. Injected so
    /// tests never touch osascript or TCC. Must honor task cancellation.
    public typealias ScriptRunner = @Sendable (_ source: String) async throws -> String

    public let timeout: TimeInterval
    private let runScript: ScriptRunner

    public init(
        timeout: TimeInterval = 2,
        runScript: @escaping ScriptRunner = BrowserTabInspector.runOSAScript
    ) {
        self.timeout = timeout
        self.runScript = runScript
    }

    public func inspectActiveTab(bundleID: String) async -> TabInspectionResult {
        guard let source = Self.script(for: MeetingApps.appFor(bundleID: bundleID)) else {
            return .unreadable
        }
        let runScript = self.runScript
        let timeout = self.timeout
        let output: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await runScript(source) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
        guard let output else { return .unreadable }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let urlLine = lines.first ?? ""
        let titleLine = lines.count > 1 ? lines[1] : ""
        return Self.matchesMeetingDomain(url: urlLine, title: titleLine) ? .meeting : .notMeeting
    }

    /// Strict host match for the URL (exact domain or dotted subdomain),
    /// substring match for the title. Internal so tests can lock the
    /// matching semantics without a script runner.
    static func matchesMeetingDomain(url: String, title: String) -> Bool {
        if let host = URL(string: url)?.host?.lowercased() {
            for domain in MeetingApps.meetingDomains {
                if host == domain || host.hasSuffix("." + domain) { return true }
            }
        }
        let lowered = title.lowercased()
        return MeetingApps.meetingDomains.contains { lowered.contains($0) }
    }

    /// One template per tab dialect, resolved from the allowlist entry.
    /// There is no bundle-ID switch here: a browser with no dialect
    /// entry takes the fallback gate by construction.
    static func script(for app: MeetingApp?) -> String? {
        guard let app else { return nil }
        switch app.tabDialect {
        case .none:
            return nil
        case .safari:
            return """
            tell application id "\(app.bundleID)"
                set u to URL of current tab of front window
                set t to name of current tab of front window
                return u & linefeed & t
            end tell
            """
        case .chromium:
            return """
            tell application id "\(app.bundleID)"
                set u to URL of active tab of front window
                set t to title of active tab of front window
                return u & linefeed & t
            end tell
            """
        }
    }

    enum InspectionError: Error {
        case scriptFailed
    }

    /// Production runner: osascript in a child process, terminated on
    /// task cancellation so a hung AppleEvent cannot outlive the timeout.
    @Sendable
    public static func runOSAScript(_ source: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    let data = stdout.fileHandleForReading.readDataToEndOfFile()
                    guard finished.terminationStatus == 0,
                        let text = String(data: data, encoding: .utf8)
                    else {
                        continuation.resume(throwing: InspectionError.scriptFailed)
                        return
                    }
                    continuation.resume(
                        returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
    }
}

extension BrowserTabInspector: BrowserTabInspecting {}
