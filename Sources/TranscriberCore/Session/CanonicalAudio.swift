import Foundation

/// Shared eligibility check for the canonical saved recording asset used by
/// failed-session retry and Recents retry affordances. `fileExists` is not
/// sufficient here: directories, FIFOs, broken nodes, and unreadable files must
/// not be treated as retryable audio.
public enum CanonicalAudio {
  public static let fileName = "audio.m4a"

  public static func url(in sessionDirectory: URL) -> URL {
    sessionDirectory.appendingPathComponent(fileName)
  }

  public static func isUsable(at audioURL: URL, fileManager: FileManager = .default) -> Bool {
    guard fileManager.isReadableFile(atPath: audioURL.path) else { return false }
    guard let values = try? audioURL.resourceValues(forKeys: [.isRegularFileKey]) else {
      return false
    }
    return values.isRegularFile == true
  }

  public static func isUsable(in sessionDirectory: URL, fileManager: FileManager = .default) -> Bool
  {
    isUsable(at: url(in: sessionDirectory), fileManager: fileManager)
  }
}
