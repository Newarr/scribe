import XCTest
@testable import TranscriberCore

final class SpeakerMappingBuilderTests: XCTestCase {
    func testOneOnOneNamesBothSpeakers() {
        let event = CalendarEvent(
            title: "1:1",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            attendees: [
                .init(name: "Szymon", isCurrentUser: true),
                .init(name: "Faris", isCurrentUser: false)
            ]
        )
        let mapping = SpeakerMappingBuilder.build(event: event)
        XCTAssertEqual(mapping[ChannelActivity.micSpeaker], "Szymon")
        XCTAssertEqual(mapping[ChannelActivity.systemSpeaker], "Faris")
    }

    func testGroupMeetingDoesNotNameSystemAudioSpeaker() {
        let event = CalendarEvent(
            title: "Team weekly",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            attendees: [
                .init(name: "Szymon", isCurrentUser: true),
                .init(name: "Faris", isCurrentUser: false),
                .init(name: "Maciek", isCurrentUser: false)
            ]
        )
        let mapping = SpeakerMappingBuilder.build(event: event)
        XCTAssertEqual(mapping[ChannelActivity.micSpeaker], "Szymon")
        XCTAssertNil(mapping[ChannelActivity.systemSpeaker], "group meetings: system audio mixes every remote voice")
    }

    func testNoEventReturnsEmptyMap() {
        let mapping = SpeakerMappingBuilder.build(event: nil)
        XCTAssertTrue(mapping.isEmpty)
    }
}
