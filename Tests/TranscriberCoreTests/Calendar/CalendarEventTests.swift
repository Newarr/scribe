import XCTest
@testable import TranscriberCore

final class CalendarEventTests: XCTestCase {
    func testCurrentUserAndFirstRemoteAttendee() {
        let now = Date()
        let event = CalendarEvent(
            title: "1:1 with Faris",
            startDate: now,
            endDate: now.addingTimeInterval(1800),
            attendees: [
                .init(name: "Szymon", isCurrentUser: true),
                .init(name: "Faris Riaz", isCurrentUser: false)
            ]
        )
        XCTAssertEqual(event.currentUser, "Szymon")
        XCTAssertEqual(event.firstRemoteAttendee, "Faris Riaz")
        XCTAssertTrue(event.isOneOnOne)
    }

    func testGroupMeetingIsNotOneOnOne() {
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
        XCTAssertFalse(event.isOneOnOne)
        XCTAssertEqual(event.firstRemoteAttendee, "Faris")
    }

    func testEventWithoutCurrentUserHasNilCurrentUser() {
        let event = CalendarEvent(
            title: "Meeting",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            attendees: [.init(name: "Faris", isCurrentUser: false)]
        )
        XCTAssertNil(event.currentUser)
        XCTAssertEqual(event.firstRemoteAttendee, "Faris")
        XCTAssertFalse(event.isOneOnOne)
    }
}
