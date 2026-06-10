import AppKit
import SwiftUI

#if DEBUG
enum DebugVisualSnapshotWriter {
    enum SnapshotError: LocalizedError {
        case renderFailed(String)

        var errorDescription: String? {
            switch self {
            case .renderFailed(let name): return "Failed to render \(name)"
            }
        }
    }

    @MainActor
    static func write<V: View>(
        _ view: V,
        named name: String,
        to directory: URL,
        scale: CGFloat = 2
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousAppearance = NSAppearance.current
        if name.localizedCaseInsensitiveContains("light") {
            NSAppearance.current = NSAppearance(named: .aqua)
        } else if name.localizedCaseInsensitiveContains("dark") {
            NSAppearance.current = NSAppearance(named: .darkAqua)
        }
        defer { NSAppearance.current = previousAppearance }
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.nsImage else {
            throw SnapshotError.renderFailed(name)
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.renderFailed(name)
        }
        try png.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }
}
#endif
