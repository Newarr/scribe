import Foundation
import XCTest

final class DocsConsistencyTests: XCTestCase {
  func testActiveDocsMatchCurrentRCBundleDomainToolchainAndLocalEngine() throws {
    let root = repositoryRoot()
    let activeDocs = try loadActiveDocs(root: root)
    let joined = activeDocs.map { "\($0.key)\n\($0.value)" }.joined(separator: "\n---\n")
    let currentVersion = try buildInfoVersion(root: root)
    let bundleID = try projectBundleIdentifier(root: root)

    XCTAssertEqual(currentVersion, "1.0.0-rc4")
    XCTAssertEqual(bundleID, "com.szymonsypniewicz.scribe")

    XCTAssertFalse(joined.contains("Local mode hidden until shipped"))
    XCTAssertFalse(joined.contains("missingLocalEngineBinary"))
    XCTAssertFalse(joined.contains("rc1 doesn't bundle the Cohere binary"))
    XCTAssertFalse(joined.contains("Cohere Rust binary"))
    XCTAssertFalse(joined.contains("Cohere Rust subprocess local engine"))

    XCTAssertFalse(joined.contains("Xcode 16"))
    XCTAssertNil(
      joined.range(of: #"Swift 6(?!\.2)"#, options: .regularExpression),
      "Use Swift 6.2-capable wording, not stale Swift 6.0-era guidance"
    )
    XCTAssertTrue(joined.contains("Xcode 26.3"))
    XCTAssertTrue(joined.contains("Swift 6.2"))

    XCTAssertFalse(joined.contains("1.0.0-rc1"))
    XCTAssertFalse(joined.contains("1.0.0-rc2"))
    XCTAssertFalse(joined.contains("rc1 stays rc1"))
    XCTAssertTrue(joined.contains(currentVersion))

    assertDefaultsCommandsUseBundleDomain(in: activeDocs, bundleID: bundleID)
  }

  func testCurrentChangelogSectionMatchesLocalEngineTruthButHistoryIsAllowed() throws {
    let root = repositoryRoot()
    let changelog = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
    let rc4 = try XCTUnwrap(changelog.section(named: "1.0.0-rc4"))

    XCTAssertTrue(rc4.contains("Local Cohere ships as an explicit engine option"))
    XCTAssertTrue(rc4.contains("beshkenadze/cohere-transcribe-03-2026-mlx-fp16"))
    XCTAssertFalse(rc4.contains("Local mode hidden until shipped"))
    XCTAssertFalse(rc4.contains("coming later"))
    XCTAssertFalse(rc4.contains("pins engineMode\n  to .cloud"))

    XCTAssertTrue(
      changelog.contains("## 1.0.0-rc1") && changelog.contains("rc1 cloud-only"),
      "Historical changelog entries are intentionally allowed to retain historical rc1 claims."
    )
  }

  private func loadActiveDocs(root: URL) throws -> [String: String] {
    let requiredPaths = [
      "README.md",
      "docs/user/PRIVACY.md",
      "docs/user/SECURITY.md",
      "docs/user/TROUBLESHOOTING.md",
      "docs/contributing/RELEASE.md",
      "docs/contributing/TESTING.md",
      "docs/contributing/STYLE.md",
    ]
    // Internal docs are untracked in the public repo (see .gitignore), so
    // they exist on dev machines but not in CI clones. Check them only
    // when present.
    let internalPaths = [
      "docs/spec/SPEC.md",
    ]
    var docs = try Dictionary(uniqueKeysWithValues: requiredPaths.map { path in
      (path, try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))
    })
    for path in internalPaths {
      let url = root.appendingPathComponent(path)
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      docs[path] = try String(contentsOf: url, encoding: .utf8)
    }
    return docs
  }

  private func buildInfoVersion(root: URL) throws -> String {
    let source = try String(contentsOf: root.appendingPathComponent("Sources/TranscriberCore/BuildInfo.swift"), encoding: .utf8)
    return try firstCapture(in: source, pattern: #"version\s*=\s*\"([^\"]+)\""#)
  }

  private func projectBundleIdentifier(root: URL) throws -> String {
    let source = try String(contentsOf: root.appendingPathComponent("TranscriberApp/project.yml"), encoding: .utf8)
    return try firstCapture(in: source, pattern: #"PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)"#)
  }

  private func assertDefaultsCommandsUseBundleDomain(in docs: [String: String], bundleID: String) {
    let defaultsPattern = #"defaults\s+(read|delete)\s+(\S+)\s+transcriber\.settings\.v1"#
    let regex = try! NSRegularExpression(pattern: defaultsPattern)
    for (path, contents) in docs {
      let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
      for match in regex.matches(in: contents, range: range) {
        let domainRange = match.range(at: 2)
        let domain = String(contents[Range(domainRange, in: contents)!])
        XCTAssertEqual(domain, bundleID, "\(path) uses stale defaults domain \(domain)")
      }
    }
  }

  private func firstCapture(in source: String, pattern: String) throws -> String {
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(source.startIndex..<source.endIndex, in: source)
    let match = try XCTUnwrap(regex.firstMatch(in: source, range: range))
    return String(source[Range(match.range(at: 1), in: source)!])
  }

  private func repositoryRoot(file: StaticString = #filePath) -> URL {
    var url = URL(fileURLWithPath: "\(file)")
    while url.lastPathComponent != "Tests" {
      url.deleteLastPathComponent()
    }
    url.deleteLastPathComponent()
    return url
  }
}

private extension String {
  func section(named heading: String) -> String? {
    let marker = "## \(heading)"
    guard let start = range(of: marker) else { return nil }
    let remainder = self[start.lowerBound...]
    if let next = remainder.range(of: "\n## ", options: [], range: remainder.index(after: start.lowerBound)..<remainder.endIndex) {
      return String(remainder[..<next.lowerBound])
    }
    return String(remainder)
  }
}
