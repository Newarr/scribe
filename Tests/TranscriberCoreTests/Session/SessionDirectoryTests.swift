import XCTest
@testable import TranscriberCore

final class SessionDirectoryTests: XCTestCase {
    var tmpRoot: URL!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    func testCreateMakesOwnerOnlyFolder() throws {
        let id = SessionID(from: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!)
        let dir = try SessionDirectory.create(under: tmpRoot, id: id)

        XCTAssertEqual(dir.url.lastPathComponent, "1970-01-01-0000")

        let attrs = try FileManager.default.attributesOfItem(atPath: dir.url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o700)
    }

    func testCollisionResolvedBySuffix() throws {
        let id = SessionID(from: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!)
        let first = try SessionDirectory.create(under: tmpRoot, id: id)
        let second = try SessionDirectory.create(under: tmpRoot, id: id)
        XCTAssertEqual(first.url.lastPathComponent, "1970-01-01-0000")
        XCTAssertEqual(second.url.lastPathComponent, "1970-01-01-0000-2")
    }

    func testPartialPaths() {
        let url = tmpRoot.appendingPathComponent("session-x")
        let dir = SessionDirectory(url: url)
        XCTAssertEqual(dir.micPartial, url.appendingPathComponent("mic.m4a.partial"))
        XCTAssertEqual(dir.systemPartial, url.appendingPathComponent("system.m4a.partial"))
        XCTAssertEqual(dir.micFinal, url.appendingPathComponent("mic.m4a"))
        XCTAssertEqual(dir.systemFinal, url.appendingPathComponent("system.m4a"))
        XCTAssertEqual(dir.ptsSidecar, url.appendingPathComponent("pts.json"))
    }

    func testAtomicRenameMicAndSystem() throws {
        let id = SessionID(from: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!)
        let dir = try SessionDirectory.create(under: tmpRoot, id: id)
        try Data("mic-data".utf8).write(to: dir.micPartial)
        try Data("system-data".utf8).write(to: dir.systemPartial)

        try dir.finalize()

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.micPartial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.systemPartial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.micFinal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.systemFinal.path))
    }
}
