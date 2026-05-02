import XCTest
@testable import TranscriberCore

final class SessionFolderEnumeratorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-folder-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: helpers

    private func writeSession(name: String, status: String, title: String, modified: Date? = nil) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let transcript = dir.appendingPathComponent("transcript.md")
        let body = """
        ---
        status: \(status)
        title: "\(title)"
        engine: elevenlabs
        ---

        body
        """
        try body.write(to: transcript, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes(
                [.modificationDate: modified],
                ofItemAtPath: dir.path
            )
        }
        return dir
    }

    // MARK: tests

    func testEmptyRootReturnsEmpty() {
        let result = SessionFolderEnumerator.recents(under: root)
        XCTAssertTrue(result.isEmpty)
    }

    func testReturnsSessionsNewestFirst() throws {
        let now = Date()
        _ = try writeSession(name: "s1", status: "complete", title: "Older",  modified: now.addingTimeInterval(-200))
        _ = try writeSession(name: "s2", status: "complete", title: "Newer",  modified: now.addingTimeInterval(-100))
        _ = try writeSession(name: "s3", status: "complete", title: "Newest", modified: now)

        let result = SessionFolderEnumerator.recents(under: root)
        XCTAssertEqual(result.map(\.title), ["Newest", "Newer", "Older"])
    }

    func testRespectsLimit() throws {
        for i in 0..<10 {
            _ = try writeSession(name: "s\(i)", status: "complete", title: "T\(i)", modified: Date().addingTimeInterval(TimeInterval(i)))
        }
        let result = SessionFolderEnumerator.recents(under: root, limit: 5)
        XCTAssertEqual(result.count, 5)
    }

    func testSkipsFoldersWithoutTranscript() throws {
        // Create a folder but no transcript.md inside.
        let bare = root.appendingPathComponent("bare", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        _ = try writeSession(name: "s1", status: "complete", title: "Real")

        let result = SessionFolderEnumerator.recents(under: root)
        XCTAssertEqual(result.map(\.title), ["Real"])
    }

    func testCorruptFrontmatterIsSkippedNotCrashed() throws {
        let dir = root.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let transcript = dir.appendingPathComponent("transcript.md")
        // No closing ---, so the frontmatter reader returns nil.
        try "garbage with no frontmatter".write(to: transcript, atomically: true, encoding: .utf8)
        _ = try writeSession(name: "ok", status: "complete", title: "OK")

        let result = SessionFolderEnumerator.recents(under: root)
        XCTAssertEqual(result.map(\.title), ["OK"])
    }

    func testStatusIsPreserved() throws {
        _ = try writeSession(name: "s1", status: "complete", title: "Done")
        _ = try writeSession(name: "s2", status: "failed",   title: "Broken", modified: Date().addingTimeInterval(-1))

        let result = SessionFolderEnumerator.recents(under: root)
        let statuses = Dictionary(uniqueKeysWithValues: result.map { ($0.title, $0.status) })
        XCTAssertEqual(statuses["Done"], .complete)
        XCTAssertEqual(statuses["Broken"], .failed)
    }
}
