import XCTest
@testable import TranscriberCore

final class KeytermSanitizerTests: XCTestCase {
    func testStripsURLsAndDomains() {
        let raw = ["1:1", "with", "Faris", "https://meet.google.com/abc-defg-hij", "today"]
        let s = KeytermSanitizer.sanitize(raw)
        XCTAssertFalse(s.contains(where: { $0.contains("://") }), "URLs must be stripped: \(s)")
        XCTAssertFalse(s.contains(where: { $0.contains("google.com") }), "domains must be stripped: \(s)")
        XCTAssertTrue(s.contains("Faris"))
    }

    func testStripsEmails() {
        let raw = ["Faris", "Riaz", "faris@ramp.network", "Project", "Rocket"]
        let s = KeytermSanitizer.sanitize(raw)
        XCTAssertFalse(s.contains(where: { $0.contains("@") }), "emails must be stripped: \(s)")
        XCTAssertTrue(s.contains("Faris"))
        XCTAssertTrue(s.contains("Project"))
    }

    func testStripsPhoneNumbers() {
        let raw = ["Dial-in", "+1-555-123-4567", "or", "555.123.4567", "to", "join"]
        let s = KeytermSanitizer.sanitize(raw)
        XCTAssertFalse(s.contains(where: { $0.contains("555") }), "phone numbers must be stripped: \(s)")
    }

    func testStripsDigitRunPasscodes() {
        let raw = ["Zoom", "passcode", "654321", "for", "Faris"]
        let s = KeytermSanitizer.sanitize(raw)
        XCTAssertFalse(s.contains("654321"), "raw passcode digits must be stripped: \(s)")
        XCTAssertFalse(s.contains("passcode"), "passcode label itself must be stripped: \(s)")
        XCTAssertTrue(s.contains("Faris"))
    }

    func testStripsLabelEqualsValue() {
        let raw = ["1:1", "PIN=987654", "with", "Faris"]
        let s = KeytermSanitizer.sanitize(raw)
        XCTAssertFalse(s.contains(where: { $0.lowercased().contains("987654") }), "PIN=value tokens must be stripped: \(s)")
        XCTAssertTrue(s.contains("Faris"))
    }

    func testKeepsRegularNamesAndWords() {
        let raw = ["Project", "Rocket", "Faris", "Riaz", "Q4", "review"]
        let s = KeytermSanitizer.sanitize(raw)
        XCTAssertEqual(Set(s), Set(["Project", "Rocket", "Faris", "Riaz", "Q4", "review"]),
                       "non-PII tokens must survive intact: \(s)")
    }

    func testCalendarEventKeytermsExcludeSecrets() {
        let event = CalendarEvent(
            title: "Faris 1:1 — meet.google.com/abc-defg passcode 123456",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            attendees: [
                .init(name: "Szymon", isCurrentUser: true),
                .init(name: "Faris", isCurrentUser: false),
                .init(name: "noreply@calendar.google.com", isCurrentUser: false),
            ]
        )
        let terms = event.keyterms
        XCTAssertTrue(terms.contains("Faris"))
        XCTAssertTrue(terms.contains("Szymon"))
        XCTAssertFalse(terms.contains(where: { $0.contains("@") }), "attendee email must be stripped: \(terms)")
        XCTAssertFalse(terms.contains(where: { $0.contains("google.com") }), "URLs must be stripped: \(terms)")
        XCTAssertFalse(terms.contains("123456"), "passcode digits must be stripped: \(terms)")
        XCTAssertFalse(terms.contains("passcode"), "passcode label must be stripped: \(terms)")
    }
}
