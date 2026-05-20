import Foundation
import XCTest

final class DevInstallScriptTests: XCTestCase {
  func testDevEntitlementsPreserveProductionSentinelAndOnlyFlipLibraryValidation() throws {
    let temp = try TemporaryDirectory()
    let production = temp.url.appendingPathComponent("production.entitlements")
    let generated = temp.url.appendingPathComponent("generated-dev-entitlements.plist")
    try fixtureProductionEntitlements.write(
      to: production,
      atomically: true,
      encoding: .utf8
    )

    let result = runScript(arguments: [
      "--make-dev-entitlements",
      production.path,
      generated.path,
    ])

    XCTAssertEqual(result.exitCode, 0, result.stderr)
    XCTAssertTrue(FileManager.default.fileExists(atPath: generated.path))
    XCTAssertTrue(
      runProcess("/usr/bin/plutil", arguments: ["-lint", generated.path]).exitCode == 0
    )

    let productionPlist = try readPlist(production)
    let generatedPlist = try readPlist(generated)
    XCTAssertEqual(generatedPlist["com.apple.security.device.audio-input"] as? Bool, true)
    XCTAssertEqual(generatedPlist["com.apple.security.cs.allow-jit"] as? Bool, false)
    XCTAssertEqual(
      generatedPlist["com.example.scribe.sentinel-entitlement"] as? String,
      "must-survive"
    )
    XCTAssertEqual(
      generatedPlist["com.example.scribe.sentinel-array"] as? [String],
      ["alpha", "beta"]
    )
    XCTAssertEqual(
      productionPlist["com.apple.security.cs.disable-library-validation"] as? Bool,
      false
    )
    XCTAssertEqual(
      generatedPlist["com.apple.security.cs.disable-library-validation"] as? Bool,
      true
    )

    var expected = productionPlist
    expected["com.apple.security.cs.disable-library-validation"] = true
    XCTAssertEqual(generatedPlist as NSDictionary, expected as NSDictionary)
  }

  func testSameSourceAndTargetIsRejectedBeforeInstallMutation() throws {
    let temp = try TemporaryDirectory()
    let app = temp.url.appendingPathComponent("Scribe.app")
    let marker = app.appendingPathComponent("Contents/MacOS/Scribe")
    try FileManager.default.createDirectory(
      at: marker.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "do not delete".write(to: marker, atomically: true, encoding: .utf8)

    let result = runScript(arguments: ["--assert-distinct-apps", app.path, app.path])

    XCTAssertNotEqual(result.exitCode, 0)
    XCTAssertTrue(result.stderr.contains("Refusing to install"), result.stderr)
    XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "do not delete")
  }

  func testDevEntitlementTempsCleanedOnSuccessAndFailure() throws {
    try assertNoTempEntitlementLeak(exitMode: "success", expectedExitCode: 0)
    try assertNoTempEntitlementLeak(exitMode: "failure", expectedExitCode: 42)
  }

  func testDevInstallScriptDoesNotEmbedStandaloneEntitlementsHeredoc() throws {
    let source = try String(contentsOf: scriptURL, encoding: .utf8)
    XCTAssertFalse(source.contains("cat > \"${DEV_ENTITLEMENTS}\""))
    XCTAssertTrue(source.contains("cp \"${production_entitlements}\" \"${output_entitlements}\""))
    XCTAssertTrue(
      source.contains("Set :com.apple.security.cs.disable-library-validation true")
    )
  }

  private func assertNoTempEntitlementLeak(exitMode: String, expectedExitCode: Int32) throws {
    let temp = try TemporaryDirectory()
    let env = [
      "TMPDIR": temp.url.path + "/",
      "SCRIBE_DEV_INSTALL_TEST_EXIT_AFTER_ENTITLEMENTS": exitMode,
    ]

    let result = runScript(arguments: [], environment: env)

    XCTAssertEqual(result.exitCode, expectedExitCode, result.stderr)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)
      .filter { $0.hasPrefix("scribe-dev-ents") }
    XCTAssertEqual(
      leftovers,
      [],
      "Leaked temp entitlement files for mode \(exitMode): \(leftovers)"
    )
  }

  private func runScript(
    arguments: [String],
    environment: [String: String] = [:]
  ) -> ProcessResult {
    runProcess(scriptURL.path, arguments: arguments, environment: environment)
  }

  private func readPlist(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    return try XCTUnwrap(plist as? [String: Any])
  }

  private var scriptURL: URL {
    repositoryRoot().appendingPathComponent("scripts/dev-install.sh")
  }

  private func repositoryRoot(file: StaticString = #filePath) -> URL {
    var url = URL(fileURLWithPath: "\(file)")
    while url.lastPathComponent != "Tests" {
      url.deleteLastPathComponent()
    }
    url.deleteLastPathComponent()
    return url
  }

  private var fixtureProductionEntitlements: String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
      "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>com.apple.security.device.audio-input</key>
      <true/>
      <key>com.apple.security.cs.allow-jit</key>
      <false/>
      <key>com.apple.security.cs.disable-library-validation</key>
      <false/>
      <key>com.example.scribe.sentinel-entitlement</key>
      <string>must-survive</string>
      <key>com.example.scribe.sentinel-array</key>
      <array>
        <string>alpha</string>
        <string>beta</string>
      </array>
    </dict>
    </plist>
    """
  }
}

private struct ProcessResult {
  let exitCode: Int32
  let stdout: String
  let stderr: String
}

@discardableResult
private func runProcess(
  _ executable: String,
  arguments: [String],
  environment: [String: String] = [:]
) -> ProcessResult {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  if !environment.isEmpty {
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in
      new
    }
  }

  let stdout = Pipe()
  let stderr = Pipe()
  process.standardOutput = stdout
  process.standardError = stderr

  do {
    try process.run()
    process.waitUntilExit()
  } catch {
    return ProcessResult(exitCode: 127, stdout: "", stderr: String(describing: error))
  }

  return ProcessResult(
    exitCode: process.terminationStatus,
    stdout: String(
      data: stdout.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) ?? "",
    stderr: String(
      data: stderr.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) ?? ""
  )
}

private final class TemporaryDirectory {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("DevInstallScriptTests-")
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}
