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
enum KeytermSanitizer {
  /// Tokens with 4+ consecutive digits are treated as PINs / conference IDs.
  /// Captures `123456`, `1234`, `phone-1234`, etc.
  private static let digitRunPattern = try! NSRegularExpression(
    pattern: #"\d{4,}"#
  )

  /// Anything that looks like a URL/link.
  ///
  /// Keep plain company/domain-like words available as recognition hints, but
  /// drop all link-shaped terms regardless of TLD: scheme URLs, `www.` URLs,
  /// and bare host/path forms such as `meet.vendor.cloud/room-abc` or
  /// `jitsi.si/team-room`. New or private TLDs are intentionally matched by
  /// shape instead of an allowlist because meeting vendors frequently use
  /// uncommon hostnames.
  private static let urlPattern = try! NSRegularExpression(
    pattern:
      #"(?ix)(https?://\S+|www\.\S+|\b[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\.[a-z]{2,}(?:[/:?&=][^\s]*|/[^\s]*))"#
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

  /// Codex rc2-audit P0 (privacy): pre-tokenization scrubber for
  /// raw event titles. The per-token `sanitize` catches 4+
  /// consecutive digits, but a spaced phone number ("+1 555 123
  /// 4567") tokenizes into chunks of 3 digits each, slipping past
  /// the digit-run filter. Run this BEFORE splitting the title on
  /// whitespace so spaced numeric sequences (phone, meeting ID,
  /// passcode) are removed in one pass.
  ///
  /// Patterns scrubbed:
  ///   - Phone-like sequences: `\+?\d` followed by 7+ chars of
  ///     digits/whitespace/punctuation, ending in a digit
  ///   - Spaced digit groups (3+ chars × 2+ groups, total 6+
  ///     digits): "123 456 789", "555 1234 5678"
  ///   - "<label> NN..." patterns: "meeting id 123 456", "passcode
  ///     1234 5678", "dial in 555 1234" — the label + everything
  ///     after up to non-numeric word
  static func scrubTitle(_ title: String) -> String {
    var result = title
    // Strip "<label> <digits ...>" patterns first since they're
    // the most common dial-in shape. Use a word-boundary regex
    // capturing the label + trailing whitespace + any sequence
    // of digit-runs separated by whitespace/punctuation.
    let labels =
      "passcode|password|pin|meeting[-\\s]?id|join[-\\s]?code|access[-\\s]?code|dial[-\\s]?in|conference[-\\s]?id|kennwort"
    let labelPattern = "(?i)\\b(\(labels))\\b\\s*[:#=]?\\s*(\\+?[0-9][0-9\\s.\\-()]*)"
    if let re = try? NSRegularExpression(pattern: labelPattern) {
      let range = NSRange(result.startIndex..<result.endIndex, in: result)
      result = re.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
    }
    // Strip phone-like spaced sequences: digit, then 7+ chars of
    // digits/whitespace/punctuation, ending on a digit. Catches
    // "+1 555 123 4567" and "(555) 123-4567" verbatim.
    let phoneish = "(?i)\\+?\\d[\\d\\s.\\-()]{7,}\\d"
    if let re = try? NSRegularExpression(pattern: phoneish) {
      let range = NSRange(result.startIndex..<result.endIndex, in: result)
      result = re.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
    }
    // Strip 2+ digit groups separated by whitespace, total length
    // 6+ digits. Catches conference IDs like "123 456 789".
    let digitGroups = "\\b\\d{3,}(?:\\s+\\d{3,}){1,}\\b"
    if let re = try? NSRegularExpression(pattern: digitGroups) {
      let range = NSRange(result.startIndex..<result.endIndex, in: result)
      result = re.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
    }
    return result
  }

  /// Sanitizes a list of candidate keyterms. Returns a (possibly shorter)
  /// list with privacy-violating tokens removed.
  static func sanitize(_ raw: [String]) -> [String] {
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
      if lower.hasPrefix("\(label):") || lower.hasPrefix("\(label)=")
        || lower.hasPrefix("\(label)-")
      {
        return true
      }
    }
    return false
  }
}
