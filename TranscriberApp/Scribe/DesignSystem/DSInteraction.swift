import AppKit
import SwiftUI

// MARK: - Hover sheen (F-11)

/// Mirrors `docs/spec/design-system/btn-sheen.js`: a 120pt radial gradient
/// that follows the cursor across button surfaces. SwiftUI doesn't
/// have a CSS-variable equivalent, so the implementation tracks the
/// mouse position via `NSTrackingArea` (wrapped in
/// `NSViewRepresentable`) and feeds it into the SwiftUI overlay.
private struct MouseLocationReader: NSViewRepresentable {
    @Binding var location: CGPoint?

    func makeNSView(context: Context) -> TrackingNSView {
        let view = TrackingNSView()
        view.onUpdate = { location = $0 }
        return view
    }

    func updateNSView(_ nsView: TrackingNSView, context: Context) {}

    final class TrackingNSView: NSView {
        var onUpdate: ((CGPoint?) -> Void)?
        private var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseMoved(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            // Flip Y so SwiftUI overlay coordinates (origin top-left)
            // match what the gradient expects.
            onUpdate?(CGPoint(x: p.x, y: bounds.height - p.y))
        }

        override func mouseExited(with event: NSEvent) {
            onUpdate?(nil)
        }
    }
}

private struct HoverSheen: ViewModifier {
    @State private var location: CGPoint?

    func body(content: Content) -> some View {
        content
            .background(
                MouseLocationReader(location: $location)
                    .allowsHitTesting(false)
            )
            .overlay(
                Group {
                    if let p = location {
                        RadialGradient(
                            colors: [SwiftUI.Color.white.opacity(0.18), SwiftUI.Color.clear],
                            center: UnitPoint(x: 0, y: 0),
                            startRadius: 0,
                            endRadius: 120
                        )
                        .offset(x: p.x - 120, y: p.y - 120)
                        .frame(width: 240, height: 240)
                        .allowsHitTesting(false)
                        .blendMode(.plusLighter)
                    }
                }
                .clipped()
            )
    }
}

extension View {
    /// Adds the radial-cursor hover sheen the design specifies for
    /// `.btn-primary` and `.btn-secondary`. No-op on touch / non-mouse
    /// surfaces because `NSTrackingArea` only fires on hover events.
    func hoverSheen() -> some View {
        modifier(HoverSheen())
    }
}
