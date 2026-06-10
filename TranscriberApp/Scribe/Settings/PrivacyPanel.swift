import SwiftUI

struct FidelityPrivacyPanel: View {
  @ObservedObject var model: SettingsFormModel
  @State private var hideFromScreenRecordings = true

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      FidelityPanelIntro(
        title: "Privacy",
        subtitle:
          "Audio files always stay on your Mac. Local (Cohere) transcription keeps everything on-device. Cloud (ElevenLabs) uploads mixed audio to ElevenLabs; when Calendar access is granted and a matching event exists, title and attendee keyterms may also be sent."
      )

      FidelitySection(title: "Visibility") {
        FidelityRow(label: "Hide from screen recordings") {
          HStack(spacing: 10) {
            FidelityToggle(isOn: $hideFromScreenRecordings)
            FidelityHelpText(
              "Scribe windows won’t appear in screenshots, screen recordings, or shared screens.")
          }
        }
      }
    }
  }
}
