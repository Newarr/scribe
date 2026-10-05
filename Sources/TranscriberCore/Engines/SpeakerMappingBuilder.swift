import Foundation

public enum SpeakerMappingBuilder {
    /// Calendar names for the channel speakers. Only 1:1 meetings name the
    /// system-audio speaker, because group meetings mix every remote voice
    /// into that channel.
    public static func build(event: CalendarEvent?) -> [String: String] {
        guard let event else { return [:] }

        var mapping: [String: String] = [:]
        if let me = event.currentUser {
            mapping[ChannelActivity.micSpeaker] = me
        }
        if event.isOneOnOne, let other = event.firstRemoteAttendee {
            mapping[ChannelActivity.systemSpeaker] = other
        }
        return mapping
    }
}
