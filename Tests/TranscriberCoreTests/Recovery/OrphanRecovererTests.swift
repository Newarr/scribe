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
}
