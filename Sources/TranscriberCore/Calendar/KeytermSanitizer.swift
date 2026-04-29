import Foundation

/// Strips tokens that the spec forbids from leaving the device unless explicitly
/// opted in: meeting URLs, dial-in phone numbers, email addresses, passcodes,
/// and long digit sequences (PINs, conference IDs, postal codes that look like
/// PINs). Spec lines 105-115:
///   "Calendar context sent: bounded keyterms only (titles, attendee display
///   names, acronyms, company/domain terms). Never raw descriptions, attendee
///   emails, meeting URLs, dial-ins, or passcodes."
///
/// Conservative by design: when in doubt, drop the token. Speech recognition
/// keyterm hints are a quality nudge, not load-bearing — losing a few legitimate
/// terms is far cheaper than leaking a passcode.
public enum KeytermSanitizer {
    /// Tokens with 4+ consecutive digits are treated as PINs / conference IDs.
    /// Captures `123456`, `1234`, `phone-1234`, etc.
    private static let digitRunPattern = try! NSRegularExpression(
        pattern: #"\d{4,}"#
    )

    /// Anything that looks like a URL, email, or phone number.
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"(?i)(https?://|www\.|[a-z0-9.-]+\.(com|org|net|io|us|co|gov|edu|app|dev|me|tv|ai|us|uk|pl)/?)"#
    )
    private static let emailPattern = try! NSRegularExpression(
        pattern: #"(?i)[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}"#
    )
    /// E.164-ish, US-style, or generic phone shapes: `+1 555-555-5555`,
    /// `(555) 555-5555`, `555.555.5555`. Any token containing a `+` followed
    /// by digits, or 3+ digit groups separated by `.-/() `.
    private static let phonePattern = try! NSRegularExpression(
        pattern: #"(?i)(\+?\d[\d\s.\-()]{7,}\d|\b\d{3}[.\-]\d{3}[.\-]\d{4}\b)"#
    )

    /// Tokens whose presence in the original text taints any nearby word as
    /// "follows a passcode-style label." The next 1-2 tokens after one of
    /// these labels are dropped along with the label itself.
    private static let secretLabels: Set<String> = [
        "passcode", "password", "pin", "code", "id", "meeting-id", "meetingid",
        "join-code", "joincode", "access-code", "accesscode", "kennwort",
    ]

    /// Sanitizes a list of candidate keyterms. Returns a (possibly shorter)
    /// list with privacy-violating tokens removed.
    public static func sanitize(_ raw: [String]) -> [String] {
        var output: [String] = []
        var skipNext = 0
        for term in raw {
            if skipNext > 0 {
                skipNext -= 1
                continue
            }
            // Bare label: drop the label and the next token which usually carries the secret.
            // Don't skip further than that — a 2-token skip swallowed unrelated names in
            // titles like "passcode 123456 with Szymon". The digit-run / URL / email
            // filters catch the value itself either way; this is just a belt-and-braces
            // strip of the label adjacent to its value.
            if secretLabels.contains(term.lowercased()) {
                skipNext = 1
                continue
            }
            // Adjacent label + value: "passcode:123456", "PIN=123456".
            if hasSecretLabelPrefix(term) { continue }
            // Pure URL / email / phone / digit run.
            if matches(urlPattern, term) { continue }
            if matches(emailPattern, term) { continue }
            if matches(phonePattern, term) { continue }
            if matches(digitRunPattern, term) { continue }
            output.append(term)
        }
        return output
    }

    private static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.firstMatch(in: s, options: [], range: range) != nil
    }

    private static func hasSecretLabelPrefix(_ term: String) -> Bool {
        let lower = term.lowercased()
        for label in secretLabels {
            if lower.hasPrefix("\(label):") || lower.hasPrefix("\(label)=") || lower.hasPrefix("\(label)-") {
                return true
            }
        }
        return false
    }
}
