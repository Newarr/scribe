import Darwin
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


    private func writeFailedSessionWithAudioNode(name: String, audioNode: AudioNodeKind) throws -> URL {
        let dir = try writeSession(name: name, status: "failed", title: name)
        let audioURL = dir.appendingPathComponent("audio.m4a")
        switch audioNode {
        case .regularFile:
            try Data("audio".utf8).write(to: audioURL)
        case .directory:
            try FileManager.default.createDirectory(at: audioURL, withIntermediateDirectories: true)
        case .symlinkToDirectory:
            let target = dir.appendingPathComponent("audio-target", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: audioURL, withDestinationURL: target)
        case .fifo:
            XCTAssertEqual(mkfifo(audioURL.path, S_IRUSR | S_IWUSR), 0)
        case .unreadableRegularFile:
            try Data("audio".utf8).write(to: audioURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: audioURL.path)
        case .missing:
            break
        }
        return dir
    }

    private enum AudioNodeKind {
        case regularFile
        case directory
        case symlinkToDirectory
        case fifo
        case unreadableRegularFile
        case missing
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

    func testFailedRecentHasSavedAudioOnlyForReadableRegularCanonicalAudio() throws {
        _ = try writeFailedSessionWithAudioNode(name: "regular", audioNode: .regularFile)
        _ = try writeFailedSessionWithAudioNode(name: "directory", audioNode: .directory)
        _ = try writeFailedSessionWithAudioNode(name: "symlink-directory", audioNode: .symlinkToDirectory)
        _ = try writeFailedSessionWithAudioNode(name: "fifo", audioNode: .fifo)
        _ = try writeFailedSessionWithAudioNode(name: "unreadable", audioNode: .unreadableRegularFile)
        _ = try writeFailedSessionWithAudioNode(name: "missing", audioNode: .missing)

        let entries = SessionFolderEnumerator.recents(under: root, limit: 10)
        let byDirectory = Dictionary(uniqueKeysWithValues: entries.map { ($0.directory.lastPathComponent, $0) })

        XCTAssertEqual(byDirectory["regular"]?.hasSavedAudio, true)
        XCTAssertEqual(byDirectory["directory"]?.hasSavedAudio, false)
        XCTAssertEqual(byDirectory["symlink-directory"]?.hasSavedAudio, false)
        XCTAssertEqual(byDirectory["fifo"]?.hasSavedAudio, false)
        XCTAssertEqual(byDirectory["unreadable"]?.hasSavedAudio, false)
        XCTAssertEqual(byDirectory["missing"]?.hasSavedAudio, false)
    }

}
