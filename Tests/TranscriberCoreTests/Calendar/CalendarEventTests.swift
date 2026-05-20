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
        .init(name: "Faris Riaz", isCurrentUser: false),
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
        .init(name: "Maciek", isCurrentUser: false),
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
        .init(name: "Faris Riaz", isCurrentUser: false),
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

  func testKeytermsDropBareMeetingLinksAcrossTLDs() {
    let event = CalendarEvent(
      title: "Vendor sync meet.vendor.cloud/room-abc and jitsi.si/team-room",
      startDate: Date(),
      endDate: Date().addingTimeInterval(1800),
      attendees: [
        .init(name: "Szymon", isCurrentUser: true),
        .init(name: "Nora Vendor", email: "nora@vendor.cloud", isCurrentUser: false),
      ]
    )

    let terms = event.keyterms
    XCTAssertTrue(terms.contains("Vendor"), "safe title words must survive: \(terms)")
    XCTAssertTrue(terms.contains("Nora Vendor"), "attendee display names must survive: \(terms)")
    XCTAssertFalse(
      terms.contains(where: { $0.contains("/") }),
      "bare meeting URL paths must be stripped: \(terms)")
    XCTAssertFalse(
      terms.contains(where: { $0.lowercased().contains("vendor.cloud") }),
      "bare meeting host must be stripped: \(terms)")
    XCTAssertFalse(
      terms.contains(where: { $0.lowercased().contains("jitsi.si") }),
      "bare meeting host must be stripped: \(terms)")
    XCTAssertFalse(
      terms.contains(where: { $0.lowercased().contains("room") }),
      "room identifiers must be stripped with URL tokens: \(terms)")
    XCTAssertLessThanOrEqual(terms.count, 16, "keyterms must remain bounded")
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
  func testCalendarEventPreservesEventIdentifierAndOccurrenceStartIdentity() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let occurrence = start.addingTimeInterval(7 * 24 * 60 * 60)
    let event = CalendarEvent(
      title: "Weekly Sync",
      startDate: start,
      endDate: start.addingTimeInterval(1800),
      attendees: [],
      eventIdentifier: "event-123",
      occurrenceStartDate: occurrence
    )

    XCTAssertEqual(event.eventIdentifier, "event-123")
    XCTAssertEqual(event.occurrenceStartDate, occurrence)
    XCTAssertEqual(event.occurrenceIdentity?.eventIdentifier, "event-123")
    XCTAssertEqual(event.occurrenceIdentity?.occurrenceStartDate, occurrence)
    XCTAssertTrue(event.calendarEventID?.contains("event-123#") == true)
    XCTAssertTrue(event.calendarEventID?.contains("2023-11-21") == true)
  }

  func testCalendarEventFallsBackToStartDateForOccurrenceIdentity() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let event = CalendarEvent(
      title: "One-off",
      startDate: start,
      endDate: start.addingTimeInterval(1800),
      attendees: [],
      eventIdentifier: "event-456"
    )

    XCTAssertEqual(event.occurrenceIdentity?.eventIdentifier, "event-456")
    XCTAssertEqual(event.occurrenceIdentity?.occurrenceStartDate, start)
  }

}
