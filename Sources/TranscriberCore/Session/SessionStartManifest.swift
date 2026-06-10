import Foundation

public struct SessionStartManifest: Codable, Equatable, Sendable {
    public static let schema = "scribe.session-start.v1"

    public let schema: String
    public let engine: String
    public let startedAt: String

    public init(engine: String, startedAt: String) {
        self.schema = Self.schema
        self.engine = engine
        self.startedAt = startedAt
    }

    public static func write(engine: String, at url: URL, now: Date = Date()) throws {
        let formatter = ISO8601DateFormatter()
        let manifest = SessionStartManifest(engine: engine, startedAt: formatter.string(from: now))
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url, options: [.atomic])
    }

    public static func read(at url: URL) -> SessionStartManifest? {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(SessionStartManifest.self, from: data),
              manifest.schema == Self.schema,
              isValidEngineIdentifier(manifest.engine)
        else { return nil }
        return manifest
    }

    public static func isValidEngineIdentifier(_ engine: String) -> Bool {
        EngineMode(persistedIdentifier: engine) != nil
    }
}
