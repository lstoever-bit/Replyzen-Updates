import Foundation

/// Scores Outlook accessibility controls without depending on Outlook's current UI language.
enum OutlookReplyControlMatcher {
    static func score(metadata: String, replyAll: Bool) -> Int {
        let normalized = metadata
            .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let allPhrases = ["reply all", "replyall", "allen antworten", "antwort an alle", "responder a todos"]
        let replyPhrases = ["reply", "antworten", "responder"]
        let containsAll = allPhrases.contains { normalized.contains($0) }

        if replyAll {
            guard containsAll else { return 0 }
            if allPhrases.contains(normalized) { return 120 }
            if normalized.contains("replyall") { return 115 }
            return 90
        }

        guard !containsAll else { return 0 }
        guard replyPhrases.contains(where: { normalized.contains($0) }) else { return 0 }
        if replyPhrases.contains(normalized) { return 120 }
        if normalized.contains("forward") || normalized.contains("weiterleiten") || normalized.contains("reenviar") { return 0 }
        return 70
    }
}
