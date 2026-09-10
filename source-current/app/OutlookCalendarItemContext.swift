import Foundation

/// Pure, testable normalization for calendar creation from either a normal email
/// or a native Outlook meeting invitation. Outlook exposes meeting cards very
/// differently from message bodies, so calendar extraction must not depend on an
/// AXWebArea being present.
enum OutlookCalendarItemContext {
    private static let acceptTokens = ["accept", "annehmen", "aceptar"]
    private static let tentativeTokens = ["tentative", "mit vorbehalt", "provisional", "tentativo", "tentativa"]
    private static let declineTokens = ["decline", "ablehnen", "rechazar"]
    private static let requiredTokens = ["required", "erforderlich", "obligatorio", "obligatoria"]
    private static let calendarTokens = ["calendar", "kalender", "calendario", "meeting", "besprechung", "termin", "appointment", "evento", "event"]

    static func looksLikeMeetingInvite(lines: [String]) -> Bool {
        let haystack = normalizedLines(lines).joined(separator: "\n").lowercased()
        guard !haystack.isEmpty else { return false }

        let responseSignals = [acceptTokens, tentativeTokens, declineTokens]
            .reduce(0) { count, group in count + (containsAny(group, in: haystack) ? 1 : 0) }

        // Outlook meeting cards normally expose at least two response controls.
        // Some compact layouts expose only one, so combine it with a scheduling cue.
        if responseSignals >= 2 { return true }
        if responseSignals == 1 {
            return containsAny(requiredTokens, in: haystack) || containsAny(calendarTokens, in: haystack)
        }
        return false
    }

    static func contextText(lines: [String]) -> String {
        let lines = normalizedLines(lines)
        guard !lines.isEmpty else { return "" }
        return (["OUTLOOK ITEM TYPE: MEETING INVITATION"] + lines)
            .joined(separator: "\n")
            .prefix(30_000)
            .description
    }

    static func normalizedLines(_ input: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        for raw in input {
            for piece in raw.components(separatedBy: .newlines) {
                let cleaned = piece
                    .replacingOccurrences(of: "\u{00A0}", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty, cleaned.count <= 2_000 else { continue }
                let key = cleaned.lowercased()
                    .replacingOccurrences(of: "  ", with: " ")
                if seen.insert(key).inserted {
                    result.append(cleaned)
                }
                if result.count >= 700 { return result }
            }
        }
        return result
    }

    private static func containsAny(_ tokens: [String], in text: String) -> Bool {
        tokens.contains { text.contains($0) }
    }
}
