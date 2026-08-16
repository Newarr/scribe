import Foundation

/// Seam `DetectionEngine` uses to gate browser candidates. Production
/// is `BrowserTabInspector`; tests inject stubs.
public protocol BrowserTabInspecting: Sendable {
    /// `true` = active tab matches a meeting domain. `false` = inspected,
    /// no match. `nil` = could not inspect; use the fallback gate.
    func activeTabMatchesMeeting(bundleID: String) async -> Bool?
}

/// Answers one question per browser candidate: does the active tab match
/// a meeting domain? `nil` means "could not inspect" (Firefox, timeout,
/// script error, missing automation grant) and the caller degrades to
/// the calendar-plus-mic gate.
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

    /// `true` = active tab matches a meeting domain. `false` = inspected,
    /// no match. `nil` = could not inspect; use the fallback gate.
    public func activeTabMatchesMeeting(bundleID: String) async -> Bool? {
        guard let source = Self.script(forBundleID: bundleID) else { return nil }
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
        guard let output else { return nil }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let urlLine = lines.first ?? ""
        let titleLine = lines.count > 1 ? lines[1] : ""
        return Self.matchesMeetingDomain(url: urlLine, title: titleLine)
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

    /// One dialect per browser family. Firefox exposes no active tab
    /// over AppleScript, so it returns nil and always takes the
    /// fallback gate. Public so the app shell can check grant coverage
    /// without running an inspection.
    public static func script(forBundleID bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Safari":
            return """
            tell application id "com.apple.Safari"
                set u to URL of current tab of front window
                set t to name of current tab of front window
                return u & linefeed & t
            end tell
            """
        case "com.google.Chrome",
             "com.microsoft.Edge",
             "com.brave.Browser",
             "company.thebrowser.Browser",
             "net.imput.helium",
             "im.helium.helium":
            return """
            tell application id "\(bundleID)"
                set u to URL of active tab of front window
                set t to title of active tab of front window
                return u & linefeed & t
            end tell
            """
        default:
            return nil
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
