import XCTest
@testable import TranscriberCore

final class OrphanRecovererTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAlreadyFinalizedIsNoOp() throws {
        let dir = SessionDirectory(url: root)
        try Data("mic".utf8).write(to: dir.micFinal)
        try Data("sys".utf8).write(to: dir.systemFinal)
        XCTAssertEqual(OrphanRecoverer.recover(dir), .alreadyFinalized)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.micFinal.path))
    }

    func testPartialFilesGetRenamed() throws {
        let dir = SessionDirectory(url: root)
        try Data("mic".utf8).write(to: dir.micPartial)
        try Data("sys".utf8).write(to: dir.systemPartial)
        XCTAssertEqual(OrphanRecoverer.recover(dir), .rescued)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.micFinal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.systemFinal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.micPartial.path))
    }

    func testMixedFinalAndPartialRenamesOnlyTheMissingSide() throws {
        // mic was finalized; system stayed partial. Rescue should rename only system.
        let dir = SessionDirectory(url: root)
        try Data("mic".utf8).write(to: dir.micFinal)
        try Data("sys".utf8).write(to: dir.systemPartial)
        XCTAssertEqual(OrphanRecoverer.recover(dir), .rescued)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.micFinal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.systemFinal.path))
    }

    func testEmptyDirReportsNoAudio() throws {
        let dir = SessionDirectory(url: root)
        XCTAssertEqual(OrphanRecoverer.recover(dir), .noAudio)
    }

    // MARK: - Phase ζ: one-sided audio (spec line 339)

    func testMicOnlyFinalReportsPartialAudio() throws {
        // System audio never made it to disk (e.g., screen recording
        // permission revoked mid-call). Spec line 339 forbids dispatching
        // a worker against a one-sided session. Recoverer must report
        // .partialAudio so SessionSupervisor writes a failed transcript
        // referencing the surviving file.
        let dir = SessionDirectory(url: root)
        try Data("mic".utf8).write(to: dir.micFinal)
        XCTAssertEqual(OrphanRecoverer.recover(dir), .partialAudio(stream: .mic))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.micFinal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.systemFinal.path))
    }

    func testSystemOnlyFinalReportsPartialAudio() throws {
        // Mirror image: mic crashed, system survived.
        let dir = SessionDirectory(url: root)
        try Data("sys".utf8).write(to: dir.systemFinal)
        XCTAssertEqual(OrphanRecoverer.recover(dir), .partialAudio(stream: .system))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.micFinal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.systemFinal.path))
    }

    func testMicOnlyPartialRenamesAndReportsPartialAudio() throws {
        // Phase ζ regression guard: a session with ONLY mic.m4a.partial
        // (system never written) must rescue the partial THEN still
        // report .partialAudio because system is missing. v0 returned
        // .rescued and would have dispatched a worker.
        let dir = SessionDirectory(url: root)
        try Data("mic-bytes".utf8).write(to: dir.micPartial)
        XCTAssertEqual(OrphanRecoverer.recover(dir), .partialAudio(stream: .mic))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.micFinal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.micPartial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.systemFinal.path))
    }

    func testSystemOnlyPartialRenamesAndReportsPartialAudio() throws {
        let dir = SessionDirectory(url: root)
        try Data("sys-bytes".utf8).write(to: dir.systemPartial)
        XCTAssertEqual(OrphanRecoverer.recover(dir), .partialAudio(stream: .system))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.micFinal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.systemFinal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.systemPartial.path))
    }
}
