import SwiftUI
import TranscriberCore

struct FidelityPanelIntro: View {
  let title: String
  let subtitle: String
  var maxWidth: CGFloat = 560

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title)
        .font(FidelitySettings.titleFont)
        .foregroundStyle(FidelitySettings.ink)
        .tracking(-0.55)
        .padding(.bottom, 6)
      Text(subtitle)
        .font(FidelitySettings.subtitleFont)
        .foregroundStyle(FidelitySettings.ink2)
        .lineSpacing(4)
        .tracking(-0.08)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .padding(.bottom, 24)
    }
  }
}

struct FidelityKeyboardShortcutDisplay: View {
  let shortcut: KeyboardShortcutSetting

  var body: some View {
    HStack(spacing: 3) {
      ForEach(Array(shortcut.displayString.map(String.init).enumerated()), id: \.offset) {
        _, part in
        FidelityKey(part)
      }
    }
  }
}

struct FidelityHelpText: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(SwiftUI.Font.custom(FidelitySettings.font, size: 11.5))
      .foregroundStyle(FidelitySettings.ink3)
      .lineSpacing(2)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct FidelitySection<Content: View>: View {
  let title: String
  let detail: String?
  @ViewBuilder var content: () -> Content

  init(title: String, detail: String? = nil, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.detail = detail
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 8) {
        Text(title.uppercased())
          .font(FidelitySettings.sectionFont)
          .foregroundStyle(FidelitySettings.ink3)
          .tracking(0.66)
        Spacer(minLength: 0)
        if let detail {
          Text(detail)
            .font(SwiftUI.Font.custom(FidelitySettings.font, size: 11).weight(.medium))
            .foregroundStyle(FidelitySettings.ink3)
            .tracking(-0.05)
        }
      }
      .padding(.horizontal, 14)
      VStack(spacing: 0) {
        content()
      }
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(FidelitySettings.groupFill)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(FidelitySettings.line, lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
  }
}

struct FidelityRow<Content: View>: View {
  let label: String
  @ViewBuilder var content: () -> Content

  var body: some View {
    HStack(alignment: .center, spacing: FidelitySettings.rowGap) {
      Text(label)
        .font(FidelitySettings.rowFont)
        .foregroundStyle(FidelitySettings.ink2)
        .tracking(-0.13)
        .frame(width: FidelitySettings.rowLabelWidth, alignment: .leading)
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 14)
    .frame(minHeight: 56)
  }
}

struct FidelityRowDivider: View {
  var body: some View {
    Rectangle()
      .fill(FidelitySettings.lineRow)
      .frame(height: 1)
  }
}

struct FidelityKey: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(FidelitySettings.keyFont)
      .foregroundStyle(FidelitySettings.ink)
      .frame(minWidth: 22, minHeight: 22)
      .padding(.horizontal, text.count > 1 ? 6 : 0)
      .background(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(FidelitySettings.keyFill)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .stroke(FidelitySettings.keyStroke, lineWidth: 1)
      )
  }
}

struct FidelityGhostButton: View {
  let title: String
  let action: () -> Void
  init(_ title: String, action: @escaping () -> Void = {}) {
    self.title = title
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(FidelitySettings.controlFont)
        .foregroundStyle(FidelitySettings.ink2)
        .frame(height: 28)
        .padding(.horizontal, 11)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(FidelitySettings.ghostButtonFill)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(FidelitySettings.ghostButtonStroke, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}

struct FidelitySecondaryButton: View {
  let title: String
  let action: () -> Void

  init(_ title: String, action: @escaping () -> Void = {}) {
    self.title = title
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(FidelitySettings.controlFont)
        .foregroundStyle(FidelitySettings.ink)
        .frame(height: 28)
        .padding(.horizontal, 11)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(FidelitySettings.secondaryButtonFill)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(FidelitySettings.secondaryButtonStroke, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}

struct FidelityToggle: View {
  @Binding var isOn: Bool

  var body: some View {
    Button {
      isOn.toggle()
    } label: {
      ZStack(alignment: .leading) {
        Capsule()
          .fill(isOn ? FidelitySettings.rust : FidelitySettings.offToggleFill)
          .overlay(
            Capsule()
              .stroke(isOn ? FidelitySettings.rust : FidelitySettings.line, lineWidth: 1)
          )
        Circle()
          .fill(SwiftUI.Color.white)
          .frame(width: 14, height: 14)
          .shadow(color: SwiftUI.Color.black.opacity(0.25), radius: 1, x: 0, y: 1)
          .offset(x: isOn ? 13 : 1)
      }
      .frame(width: 30, height: 18)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .contentShape(Capsule())
    .accessibilityElement()
    .accessibilityLabel("Switch")
    .accessibilityValue(isOn ? "on" : "off")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { isOn.toggle() }
  }
}
