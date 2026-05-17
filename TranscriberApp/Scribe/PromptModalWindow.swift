import AppKit
import SwiftUI

@MainActor
enum PromptModalWindow {
    enum Decision {
        case primary
        case secondary
        case dismissed
    }

    struct Model {
        var badge: String
        var title: String
        var message: String
        var secondaryTitle: String
        var primaryTitle: String
    }

    static func run(
        model: Model,
        place: (NSWindow) -> Void,
        onWindowReady: (NSWindow) -> Void = { _ in }
    ) -> Decision {
        var decision: Decision = .dismissed

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .modalPanel
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.sharingType = WindowChromeSharing.confidential
        panel.defaultButtonCell = nil

        let root = PromptModalView(
            model: model,
            onSecondary: {
                decision = .secondary
                NSApp.stopModal(withCode: .alertSecondButtonReturn)
            },
            onPrimary: {
                decision = .primary
                NSApp.stopModal(withCode: .alertFirstButtonReturn)
            }
        )
        let host = NSHostingView(rootView: root)
        panel.contentView = host

        let fitting = host.fittingSize
        panel.setContentSize(NSSize(
            width: 520,
            height: max(210, fitting.height)
        ))
        WindowChrome.installGlass(on: panel, material: .hudWindow)

        place(panel)
        onWindowReady(panel)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        _ = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        panel.close()

        return decision
    }
}

private struct PromptModalView: View {
    let model: PromptModalWindow.Model
    let onSecondary: @MainActor () -> Void
    let onPrimary: @MainActor () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = PromptPalette(colorScheme: colorScheme)

        VStack(spacing: 0) {
            header(palette: palette)
            Rectangle()
                .fill(palette.dividerLine)
                .frame(height: 1)
            VStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(model.title)
                        .font(.custom(DS.sansFamily, size: 23).weight(.semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.message)
                        .font(.custom(DS.sansFamily, size: 14))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Button(action: onSecondary) {
                        Text(model.secondaryTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PromptSecondaryButtonStyle(palette: palette))

                    Button(action: onPrimary) {
                        Text(model.primaryTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PromptPrimaryButtonStyle(palette: palette))
                }
            }
            .padding(.top, 30)
            .padding(.horizontal, 30)
            .padding(.bottom, 26)
        }
        .frame(width: 520)
        .background(PromptSurfaceBackground(palette: palette))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.outerStroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .glassBackground()
    }

    private func header(palette: PromptPalette) -> some View {
        HStack(spacing: 6) {
            MenuHeaderMark()
                .fill(palette.text)
                .frame(width: 18, height: 18)
            Text("scribe")
                .font(.custom(DS.sansFamily, size: 13).weight(.semibold))
                .foregroundStyle(palette.text)
            Spacer(minLength: 0)
            HStack(spacing: 7) {
                Circle()
                    .fill(palette.neutralStatus)
                    .frame(width: 6, height: 6)
                Text(model.badge.uppercased())
                    .font(.custom(DS.monoFamily, size: 10).weight(.medium))
                    .tracking(0.7)
                    .foregroundStyle(palette.neutralStatus)
            }
        }
        .frame(height: 58)
        .padding(.horizontal, 26)
    }
}

private struct PromptPalette {
    let colorScheme: ColorScheme

    var isDark: Bool { colorScheme == .dark }

    var surfaceBase: SwiftUI.Color {
        isDark
            ? SwiftUI.Color(red: 7 / 255, green: 1 / 255, blue: 3 / 255)
            : SwiftUI.Color(red: 245 / 255, green: 247 / 255, blue: 250 / 255)
    }

    var surfaceCoolTint: SwiftUI.Color {
        isDark
            ? SwiftUI.Color(red: 77 / 255, green: 13 / 255, blue: 26 / 255).opacity(0.50)
            : SwiftUI.Color(red: 220 / 255, green: 234 / 255, blue: 251 / 255).opacity(0.62)
    }

    var surfaceWarmTint: SwiftUI.Color {
        isDark
            ? SwiftUI.Color(red: 92 / 255, green: 28 / 255, blue: 18 / 255).opacity(0.26)
            : SwiftUI.Color(red: 255 / 255, green: 224 / 255, blue: 214 / 255).opacity(0.50)
    }

    var text: SwiftUI.Color {
        isDark
            ? SwiftUI.Color(red: 250 / 255, green: 250 / 255, blue: 250 / 255)
            : SwiftUI.Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255)
    }

    var secondaryText: SwiftUI.Color {
        isDark
            ? SwiftUI.Color(red: 184 / 255, green: 184 / 255, blue: 184 / 255)
            : SwiftUI.Color(red: 71 / 255, green: 71 / 255, blue: 71 / 255)
    }

    var neutralStatus: SwiftUI.Color {
        isDark
            ? SwiftUI.Color(red: 122 / 255, green: 122 / 255, blue: 122 / 255)
            : SwiftUI.Color(red: 128 / 255, green: 122 / 255, blue: 117 / 255)
    }

    var dividerLine: SwiftUI.Color {
        isDark
            ? SwiftUI.Color.white.opacity(15 / 255)
            : SwiftUI.Color.black.opacity(10 / 255)
    }

    var outerStroke: SwiftUI.Color {
        isDark
            ? SwiftUI.Color.white.opacity(26 / 255)
            : SwiftUI.Color.black.opacity(18 / 255)
    }

    var buttonStroke: SwiftUI.Color {
        isDark
            ? SwiftUI.Color.white.opacity(26 / 255)
            : SwiftUI.Color.black.opacity(31 / 255)
    }

    var hoverFill: SwiftUI.Color {
        isDark
            ? SwiftUI.Color.white.opacity(0.055)
            : SwiftUI.Color.black.opacity(0.055)
    }

    var primaryButtonFill: SwiftUI.Color { text }
    var primaryButtonText: SwiftUI.Color {
        isDark ? SwiftUI.Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255) : .white
    }
}

private struct PromptSurfaceBackground: View {
    let palette: PromptPalette

    var body: some View {
        ZStack {
            palette.surfaceBase
            RadialGradient(
                colors: [palette.surfaceCoolTint, SwiftUI.Color.clear],
                center: UnitPoint(x: 0.75, y: 0.06),
                startRadius: 0,
                endRadius: 440
            )
            RadialGradient(
                colors: [palette.surfaceWarmTint, SwiftUI.Color.clear],
                center: UnitPoint(x: 0.03, y: 0.01),
                startRadius: 0,
                endRadius: 380
            )
        }
    }
}

private struct PromptPrimaryButtonStyle: ButtonStyle {
    let palette: PromptPalette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.button)
            .foregroundStyle(palette.primaryButtonText)
            .padding(.horizontal, 15)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(palette.primaryButtonFill.opacity(configuration.isPressed ? 0.82 : 1))
            )
    }
}

private struct PromptSecondaryButtonStyle: ButtonStyle {
    let palette: PromptPalette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.button)
            .foregroundStyle(palette.text)
            .padding(.horizontal, 15)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(configuration.isPressed ? palette.hoverFill : SwiftUI.Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(palette.buttonStroke, lineWidth: 1)
            )
    }
}
