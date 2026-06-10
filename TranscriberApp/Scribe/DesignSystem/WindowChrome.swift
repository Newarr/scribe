import AppKit
import SwiftUI

// MARK: - Confidential UI sharing type

/// `NSWindow.sharingType` per codex UX-4 (confidential UI must not
/// appear in screen-shared video). Both Debug and Release builds
/// return `.none` by default so prompts and popovers never appear in
/// screen-shared video regardless of build configuration.
///
/// To enable screen capture during visual testing or screenshot
/// automation set the environment variable
/// `SCRIBE_VISUAL_TEST_OVERRIDE=1` before launching the app.
/// This override is intentional and explicit; it must not be set in
/// production or CI acceptance runs.
@MainActor
enum WindowChromeSharing {
    static var confidential: NSWindow.SharingType {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SCRIBE_VISUAL_TEST_OVERRIDE"] == "1" {
            return .readWrite
        }
        #endif
        return .none
    }
}

// MARK: - Permission-flow window focus

@MainActor
enum WindowFrontRestorer {
    static func bringFront(_ window: NSWindow) {
        window.level = .floating
        window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        Task { @MainActor [weak window] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let window, window.isVisible else { return }
            window.level = .normal
        }
    }

    static func restoreAfterPermissionPrompt(_ window: NSWindow?) {
        guard let window else { return }
        bringFront(window)
        Task { @MainActor [weak window] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let window, window.isVisible else { return }
            bringFront(window)
        }
    }
}

// MARK: - Liquid Glass window chrome

/// Wraps an `NSWindow`'s contents in an `NSVisualEffectView` so the
/// surface picks up system vibrancy, then strips the title bar so the
/// glass extends edge-to-edge. The SwiftUI content this hosts must use
/// `Color.clear` (or the `.glassBackground()` modifier below) for its
/// outermost background, otherwise the blur is occluded.
///
/// `material` defaults to `.windowBackground` for full windows;
/// menu-bar popovers should pass `.hudWindow` for the tighter HUD
/// vibrancy the design specifies.
@MainActor
enum WindowChrome {
    static func installGlass(
        on window: NSWindow,
        material: NSVisualEffectView.Material = .windowBackground
    ) {
        // Codex UX-4 stays satisfied: NSVisualEffectView does not
        // bypass the window's `sharingType`; the wrapper inherits the
        // window's exclusion from screen capture.
        guard let host = window.contentView else { return }

        let blur = NSVisualEffectView(frame: host.bounds)
        blur.material = material
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false

        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor)
        ])

        window.contentView = blur

        // Titlebar transparent + hidden title so glass reaches the top
        // edge. Spec requires the SwiftUI body to carry any title text
        // (the brand wordmark in PrivacyAcknowledgement, content
        // headings in Settings/Diagnostics).
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
    }
}

@MainActor
extension WindowChrome {
    /// Wraps an `NSHostingController`'s view in an `NSVisualEffectView`
    /// so an `NSPopover` reads with the same Liquid Glass treatment as
    /// the design's menu bar popover. NSPopover supplies its own
    /// system chrome but the SwiftUI host view sits ON TOP of that
    /// chrome; without a vibrancy wrapper the host occludes the blur.
    static func wrapInGlass<V: View>(
        controller: NSHostingController<V>,
        material: NSVisualEffectView.Material = .hudWindow
    ) {
        let host = controller.view
        let blur = NSVisualEffectView(frame: host.bounds)
        blur.material = material
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false

        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor)
        ])
        controller.view = blur
    }
}

/// Adds the design's 1px specular highlight to the very top edge of any
/// SwiftUI surface presented in a glass window. The gradient is
/// `white.opacity(0.08) → clear` confined to a 1pt-tall hairline,
/// matching the design preview's `.surface::before` pseudo-element.
struct GlassSpecularHighlight: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [SwiftUI.Color.white.opacity(0.08), SwiftUI.Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 1)
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// Backdrop for SwiftUI surfaces hosted by a glass window. Replaces
    /// the previous `.background(DS.Color.background)` calls so the
    /// `NSVisualEffectView` underneath shows through.
    func glassBackground() -> some View {
        background(SwiftUI.Color.clear)
            .overlay(GlassSpecularHighlight(), alignment: .top)
    }
}
