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

    /// Codex rc2-audit P0: a calendar event titled `Acme dial in +1
    /// 555 123 4567 meeting id 123 456 789` tokenizes via whitespace
    /// BEFORE per-token sanitization, leaving 3-digit chunks
    /// ("555","123","456","789") that pass through the 4+-digit-run
    /// filter. KeytermSanitizer.scrubTitle must remove these spaced
    /// digit sequences before tokenization so they never reach the
    /// engine upload.
    func testSpacedDialInDoesNotLeakDigitFragments() {
        let event = CalendarEvent(
            title: "Acme dial in +1 555 123 4567 meeting id 123 456 789",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            attendees: [.init(name: "Szymon", isCurrentUser: true)]
        )
        let terms = event.keyterms
        for sentinel in ["555", "123", "456", "789", "4567"] {
            XCTAssertFalse(
                terms.contains(sentinel),
                "spaced phone/meeting-id digit fragment \(sentinel) leaked into keyterms: \(terms)"
            )
        }
        XCTAssertTrue(terms.contains("Acme"), "regular title words must survive: \(terms)")
    }

    func testSpacedConferenceIDIsScrubbed() {
        // "Project Rocket 123 456 789" → "Project", "Rocket" only.
        let event = CalendarEvent(
            title: "Project Rocket 123 456 789",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            attendees: [.init(name: "Szymon", isCurrentUser: true)]
        )
        let terms = event.keyterms
        XCTAssertTrue(terms.contains("Project"))
        XCTAssertTrue(terms.contains("Rocket"))
        for digit in ["123", "456", "789"] {
            XCTAssertFalse(terms.contains(digit), "spaced conference-id digit \(digit) leaked: \(terms)")
        }
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
