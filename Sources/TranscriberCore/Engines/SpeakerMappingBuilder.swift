import Foundation

public enum SpeakerMappingBuilder {
    /// Build the speaker -> display name map fed to `TranscriptWriter.writeComplete`.
    /// Empty map means the writer renders raw speaker IDs (`speaker_0`, etc.).
    ///
    /// Multichannel mode: speaker_0 is the mic channel (the local user), speaker_1
    /// is the system channel (remote). Map both only for 1:1 meetings, since group
    /// meetings have multiple remotes mixed onto ch1 and a single name there is
    /// misleading.
    ///
    /// Single-channel diarized mode: ElevenLabs assigns speaker_0 / speaker_1 by
    /// voice clustering, not channel. The cluster ID does not reliably correspond
    /// to mic vs system, so we never auto-map. Slice 6 may revisit if calendar
    /// attendees prove distinctive enough.
    public static func build(event: CalendarEvent?, mode: EngineRequest.Mode) -> [String: String] {
        guard case .multichannel = mode, let event else { return [:] }

        var mapping: [String: String] = [:]
        if let me = event.currentUser {
            mapping["speaker_0"] = me
        }
        if event.isOneOnOne, let other = event.firstRemoteAttendee {
            mapping["speaker_1"] = other
        }
        return mapping
    }
}
