import Foundation
import XCTest

final class ReleaseVersionScriptTests: XCTestCase {
  func testBumpVersionAcceptsStrictSemVerAndKeepsBundleShortVersionNumeric() throws {
    let accepted = [
      ("1.0.0", "1.0.0"),
      ("1.0.0-rc.1", "1.0.0"),
      ("1.2.3-rc.1+build.42", "1.2.3"),
    ]

    for (version, bundleVersion) in accepted {
      let fixture = try VersionFixture()
      let result = fixture.runBump(version)

      XCTAssertEqual(result.exitCode, 0, result.stderr)
      XCTAssertTrue(fixture.buildInfo().contains("public static let version = \"\(version)\""))
      XCTAssertTrue(fixture.projectYML().contains("MARKETING_VERSION: \"\(bundleVersion)\""))
      XCTAssertTrue(fixture.projectYML().contains("CURRENT_PROJECT_VERSION: \"6\""))
      XCTAssertTrue(fixture.changelog().contains("## \(version) - "))
      if version != bundleVersion {
        XCTAssertFalse(fixture.projectYML().contains("MARKETING_VERSION: \"\(version)\""))
      }
    }
  }

  func testBumpVersionRejectsInvalidSemVerWithoutPartialEdits() throws {
    let rejected = [
      "01.0.0",
      "1.0.0-01",
      "1.0.0-rc..1",
      "1.0.0+build..1",
    ]

    for version in rejected {
      let fixture = try VersionFixture()
      let beforeBuildInfo = fixture.buildInfo()
      let beforeProject = fixture.projectYML()
      let beforeChangelog = fixture.changelog()

      let result = fixture.runBump(version)

      XCTAssertNotEqual(result.exitCode, 0, "\(version) should be rejected")
      XCTAssertTrue(result.stderr.contains("not valid SemVer 2.0"), result.stderr)
      XCTAssertEqual(fixture.buildInfo(), beforeBuildInfo)
      XCTAssertEqual(fixture.projectYML(), beforeProject)
      XCTAssertEqual(fixture.changelog(), beforeChangelog)
    }
  }

  func testRepositoryBundleShortVersionSurfacesAreNumericOnly() throws {
    let root = repositoryRoot()
    let projectYML = try String(
      contentsOf: root.appendingPathComponent("TranscriberApp/project.yml"),
      encoding: .utf8
    )
    let xcodeProject = try String(
      contentsOf: root.appendingPathComponent("TranscriberApp/Scribe.xcodeproj/project.pbxproj"),
      encoding: .utf8
    )

    for source in [projectYML, xcodeProject] {
      for line in source.components(separatedBy: .newlines) where line.contains("MARKETING_VERSION")
      {
        let separator: Character = line.contains("=") ? "=" : ":"
        let value = try XCTUnwrap(line.split(separator: separator).last)
          .trimmingCharacters(in: CharacterSet(charactersIn: " \t;\""))
        XCTAssertTrue(Self.isNumericBundleShortVersion(value), line)
        XCTAssertFalse(value.contains("-"), line)
        XCTAssertFalse(value.contains("+"), line)
      }
    }
  }

  func testReleaseScriptComparesAppleBundleVersionAgainstNumericBase() throws {
    let source = try String(
      contentsOf: repositoryRoot().appendingPathComponent("scripts/release.sh"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("BUNDLE_SHORT_VERSION=\"${VERSION%%[-+]*}\""))
    XCTAssertTrue(source.contains(#"${PROJECT_VERSION}" != "${BUNDLE_SHORT_VERSION}"#))
    XCTAssertTrue(source.contains(#"${DMG_BUNDLE_VERSION}" != "${BUNDLE_SHORT_VERSION}"#))
    XCTAssertTrue(source.contains(#"${EXPECTED_VERSION}" != "${VERSION}"#))
  }

  func testReleaseFixtureValidationDoesNotRequireReleaseOnlyCredentials() throws {
    let result = runProcess(
      repositoryRoot().appendingPathComponent("scripts/release.sh").path,
      arguments: ["--fixture-validate"],
      currentDirectory: repositoryRoot()
    )

    XCTAssertEqual(result.exitCode, 0, result.stderr)
    XCTAssertFalse(result.stderr.contains("create-dmg"), result.stderr)
    XCTAssertFalse(result.stderr.contains("codesign-identity"), result.stderr)
    XCTAssertFalse(result.stderr.contains("scribe-notary"), result.stderr)
  }

  func testExportOptionsEscapesDeveloperIDIdentityWithXMLCharacters() throws {
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("ReleaseVersionScriptTests")
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("ExportOptions.plist")
    try FileManager.default.createDirectory(
      at: output.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }

    let identity = "Developer ID Application: A & B <Team> (TEAMID)"
    let result = runProcess(
      repositoryRoot().appendingPathComponent("scripts/release.sh").path,
      arguments: ["--fixture-export-options", output.path, identity],
      currentDirectory: repositoryRoot()
    )

    XCTAssertEqual(result.exitCode, 0, result.stderr)
    XCTAssertEqual(
      runProcess("/usr/bin/plutil", arguments: ["-lint", output.path]).exitCode,
      0
    )
    XCTAssertEqual(
      runProcess(
        "/usr/libexec/PlistBuddy",
        arguments: ["-c", "Print :signingCertificate", output.path]
      ).stdout.trimmingCharacters(in: .whitespacesAndNewlines),
      identity
    )
  }

  func testReleaseBuildIntermediatesAreExcludedFromGitAndDiscovery() throws {
    let root = repositoryRoot()
    let generatedIntermediate =
      "TranscriberApp/.dd-release/Build/Intermediates.noindex/Scribe.build/DerivedSources/GeneratedAssetSymbols.swift"
    let genericIntermediate =
      "scratch/Build/Intermediates.noindex/Scribe.build/DerivedSources/resource_bundle_accessor.swift"

    XCTAssertEqual(
      runProcess(
        "/usr/bin/git",
        arguments: ["check-ignore", "-q", generatedIntermediate],
        currentDirectory: root
      ).exitCode,
      0
    )
    XCTAssertEqual(
      runProcess(
        "/usr/bin/git",
        arguments: ["check-ignore", "-q", genericIntermediate],
        currentDirectory: root
      ).exitCode,
      0
    )
    XCTAssertNotEqual(
      runProcess(
        "/usr/bin/git",
        arguments: ["ls-files", "--error-unmatch", generatedIntermediate],
        currentDirectory: root
      ).exitCode,
      0
    )

    let clawpatchConfig = try String(
      contentsOf: root.appendingPathComponent(".clawpatch/config.json"),
      encoding: .utf8
    )
    XCTAssertTrue(clawpatchConfig.contains(#""TranscriberApp/.dd-release/**""#))
    XCTAssertTrue(clawpatchConfig.contains(#""**/Build/Intermediates.noindex/**""#))
    XCTAssertTrue(clawpatchConfig.contains(#""**/Build/Intermediates/**""#))
    XCTAssertTrue(clawpatchConfig.contains(#""**/DerivedSources/**""#))

    let project = try String(
      contentsOf: root.appendingPathComponent("TranscriberApp/Scribe.xcodeproj/project.pbxproj"),
      encoding: .utf8
    )
    XCTAssertFalse(project.contains("TranscriberApp/.dd-release"))
    XCTAssertFalse(project.contains("Intermediates.noindex"))
    XCTAssertFalse(project.contains("DerivedSources"))
  }

  static func isStrictSemVer(_ value: String) -> Bool {
    let numericIdentifier = #"0|[1-9][0-9]*"#
    let prereleaseIdentifier = #"(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"#
    let buildIdentifier = #"[0-9A-Za-z-]+"#
    let pattern =
      "^(" + numericIdentifier + ")\\.(" + numericIdentifier + ")\\.("
      + numericIdentifier + ")(-(" + prereleaseIdentifier + ")(\\.("
      + prereleaseIdentifier + "))*)?(\\+(" + buildIdentifier + ")(\\.("
      + buildIdentifier + "))*)?$"
    return value.range(of: pattern, options: .regularExpression) != nil
  }

  private static func isNumericBundleShortVersion(_ value: String) -> Bool {
    value.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
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

private final class VersionFixture {
  let root: URL

  init(file: StaticString = #filePath) throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ReleaseVersionScriptTests")
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("scripts"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Sources/TranscriberCore"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("TranscriberApp"),
      withIntermediateDirectories: true
    )

    let repoRoot = Self.repositoryRoot(file: file)
    try FileManager.default.copyItem(
      at: repoRoot.appendingPathComponent("scripts/bump-version.sh"),
      to: root.appendingPathComponent("scripts/bump-version.sh")
    )
    try "public enum BuildInfo {\n    public static let version = \"1.0.0-rc4\"\n}\n"
      .write(
        to: root.appendingPathComponent("Sources/TranscriberCore/BuildInfo.swift"),
        atomically: true,
        encoding: .utf8
      )
    try """
    name: Scribe
    settings:
      base:
        MARKETING_VERSION: "1.0.0-rc4"
        CURRENT_PROJECT_VERSION: "5"
    """.write(
      to: root.appendingPathComponent("TranscriberApp/project.yml"),
      atomically: true,
      encoding: .utf8
    )
    try "# Changelog\n\n## 1.0.0-rc4 - 2026-05-01\n\n- Existing.\n".write(
      to: root.appendingPathComponent("CHANGELOG.md"),
      atomically: true,
      encoding: .utf8
    )

    XCTAssertEqual(
      runProcess("/usr/bin/git", arguments: ["init"], currentDirectory: root).exitCode, 0)
    XCTAssertEqual(
      runProcess("/usr/bin/git", arguments: ["add", "."], currentDirectory: root).exitCode, 0)
    XCTAssertEqual(
      runProcess(
        "/usr/bin/git",
        arguments: [
          "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
          "commit", "-m", "fixture",
        ],
        currentDirectory: root
      ).exitCode,
      0
    )
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  func runBump(_ version: String) -> ScriptProcessResult {
    runProcess(
      root.appendingPathComponent("scripts/bump-version.sh").path,
      arguments: [version],
      currentDirectory: root
    )
  }

  func buildInfo() -> String {
    (try? String(
      contentsOf: root.appendingPathComponent("Sources/TranscriberCore/BuildInfo.swift"),
      encoding: .utf8
    )) ?? ""
  }

  func projectYML() -> String {
    (try? String(
      contentsOf: root.appendingPathComponent("TranscriberApp/project.yml"),
      encoding: .utf8
    )) ?? ""
  }

  func changelog() -> String {
    (try? String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)) ?? ""
  }

  private static func repositoryRoot(file: StaticString) -> URL {
    var url = URL(fileURLWithPath: "\(file)")
    while url.lastPathComponent != "Tests" {
      url.deleteLastPathComponent()
    }
    url.deleteLastPathComponent()
    return url
  }
}

private struct ScriptProcessResult {
  let exitCode: Int32
  let stdout: String
  let stderr: String
}

@discardableResult
private func runProcess(
  _ executable: String,
  arguments: [String],
  currentDirectory: URL? = nil
) -> ScriptProcessResult {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.currentDirectoryURL = currentDirectory

  let stdout = Pipe()
  let stderr = Pipe()
  process.standardOutput = stdout
  process.standardError = stderr

  do {
    try process.run()
    process.waitUntilExit()
  } catch {
    return ScriptProcessResult(exitCode: 127, stdout: "", stderr: String(describing: error))
  }

  return ScriptProcessResult(
    exitCode: process.terminationStatus,
    stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
    stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  )
}
