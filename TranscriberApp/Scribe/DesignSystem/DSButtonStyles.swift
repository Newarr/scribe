import SwiftUI

// MARK: - Button styles

/// Primary action. `.btn-primary` from index.html: white bg, dark
/// text. 28pt height, 11pt horizontal padding, 6pt radius.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.button)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .foregroundStyle(SwiftUI.Color(red: 0.04, green: 0.04, blue: 0.04))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(SwiftUI.Color.white)
                    .opacity(configuration.isPressed ? 0.85 : 1.0)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Secondary. `.btn-secondary` from index.html: translucent white
/// fill `oklch(1 0 0 / 0.04)` with `oklch(1 0 0 / 0.10)` border.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.button)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .foregroundStyle(DS.Color.foreground)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(SwiftUI.Color.white.opacity(configuration.isPressed ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(SwiftUI.Color.white.opacity(configuration.isPressed ? 0.18 : 0.10), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Ghost. `.btn-ghost`: transparent, ink-2 color until hover.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.button)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .foregroundStyle(configuration.isPressed ? DS.Color.foreground : DS.Color.foregroundSecondary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(SwiftUI.Color.white.opacity(configuration.isPressed ? 0.04 : 0.0))
            )
    }
}

/// Link, text-only action with the rust-2 color, underline on press.
struct DSLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.button)
            .foregroundStyle(DS.Color.recordingLight)
            .underline(configuration.isPressed)
    }
}
