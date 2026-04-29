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

    func testKeytermsCombineTitleWordsAndAttendees() {
        let event = CalendarEvent(
            title: "1:1 with Faris on Project Rocket",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            attendees: [
                .init(name: "Szymon Sypniewicz", isCurrentUser: true),
                .init(name: "Faris Riaz", isCurrentUser: false)
            ]
        )
        let terms = event.keyterms
        XCTAssertTrue(terms.contains("with"))
        XCTAssertTrue(terms.contains("Faris"))
        XCTAssertTrue(terms.contains("Project"))
        XCTAssertTrue(terms.contains("Rocket"))
        XCTAssertTrue(terms.contains("Szymon Sypniewicz"))
        XCTAssertTrue(terms.contains("Faris Riaz"))
        // "1:1" stripped (length <= 2 after punctuation strip) and "on" filtered out
        XCTAssertFalse(terms.contains("on"))
        XCTAssertLessThanOrEqual(terms.count, 16, "keyterms must be bounded")
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
