import XCTest
@testable import TranscriberCore

final class SpeakerMappingBuilderTests: XCTestCase {
    func testOneOnOneMultichannelMapsBothSpeakers() {
        let event = CalendarEvent(
            title: "1:1",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            attendees: [
                .init(name: "Szymon", isCurrentUser: true),
                .init(name: "Faris", isCurrentUser: false)
            ]
        )
        let mapping = SpeakerMappingBuilder.build(event: event, mode: .multichannel)
        XCTAssertEqual(mapping["speaker_0"], "Szymon")
        XCTAssertEqual(mapping["speaker_1"], "Faris")
    }

    func testGroupMeetingDoesNotMapSpeakerOne() {
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
        let mapping = SpeakerMappingBuilder.build(event: event, mode: .multichannel)
        XCTAssertEqual(mapping["speaker_0"], "Szymon")
        XCTAssertNil(mapping["speaker_1"], "group meetings: speaker_1 stays unmapped, downstream renders it raw")
    }

    func testNoEventReturnsEmptyMap() {
        let mapping = SpeakerMappingBuilder.build(event: nil, mode: .multichannel)
        XCTAssertTrue(mapping.isEmpty)
    }

    func testSingleChannelDiarizedReturnsEmptyMapEvenWithEvent() {
        let event = CalendarEvent(
            title: "1:1",
            startDate: Date(), endDate: Date().addingTimeInterval(1800),
            attendees: [
                .init(name: "Szymon", isCurrentUser: true),
                .init(name: "Faris", isCurrentUser: false)
            ]
        )
        let mapping = SpeakerMappingBuilder.build(event: event, mode: .singleChannelDiarized(numSpeakers: 2))
        XCTAssertTrue(mapping.isEmpty)
    }
}
