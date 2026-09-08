import Foundation
import NaturalLanguage

/// Detects the language of the newest relevant message rather than the full quoted thread.
enum MailLanguageDetector {
    static func detect(in mailText: String) -> AppState.ReplyLanguage? {
        let sample = latestMessageSample(from: mailText)
        guard sample.count >= 8 else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let dominant = recognizer.dominantLanguage else { return nil }

        let mapped: AppState.ReplyLanguage
        switch dominant {
        case .german: mapped = .german
        case .english: mapped = .usEnglish
        case .spanish: mapped = .spanish
        default: return nil
        }

        let confidence = recognizer.languageHypotheses(withMaximum: 4)[dominant] ?? 0
        let threshold = sample.count < 60 ? 0.45 : 0.30
        guard confidence >= threshold else { return nil }
        return mapped
    }

    static func latestMessageSample(from mailText: String) -> String {
        let normalized = mailText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var current: [String] = []
        var accumulatedCharacters = 0

        for index in lines.indices {
            let raw = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = raw.lowercased()

            if accumulatedCharacters >= 8 && isExplicitHistoryMarker(lower) {
                break
            }

            if accumulatedCharacters >= 8 && isHeaderStart(lower),
               looksLikeQuotedHeaderGroup(lines: lines, start: index) {
                break
            }

            current.append(raw)
            accumulatedCharacters += raw.count
            if accumulatedCharacters >= 3_000 { break }
        }

        var sample = current.joined(separator: "\n")
        sample = sample.replacingOccurrences(
            of: #"https?://\S+|www\.\S+|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            with: " ", options: [.regularExpression, .caseInsensitive]
        )
        sample = sample.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String(sample.trimmingCharacters(in: .whitespacesAndNewlines).prefix(3_000))
    }

    private static func isExplicitHistoryMarker(_ lower: String) -> Bool {
        if lower.contains("original message") || lower.contains("ursprüngliche nachricht") ||
            lower.contains("mensaje original") { return true }
        if lower.hasPrefix("on ") && lower.hasSuffix(" wrote:") { return true }
        if lower.hasPrefix("am ") && lower.contains(" schrieb ") && lower.hasSuffix(":") { return true }
        if lower.hasPrefix("el ") && lower.contains(" escribió") && lower.hasSuffix(":") { return true }
        return false
    }

    private static func isHeaderStart(_ lower: String) -> Bool {
        lower.hasPrefix("from:") || lower.hasPrefix("von:") || lower.hasPrefix("de:")
    }

    private static func looksLikeQuotedHeaderGroup(lines: [String], start: Int) -> Bool {
        let end = min(lines.count, start + 7)
        guard start + 1 < end else { return false }
        let following = lines[(start + 1)..<end].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let hasSent = following.contains { $0.hasPrefix("sent:") || $0.hasPrefix("gesendet:") || $0.hasPrefix("enviado:") }
        let hasTo = following.contains { $0.hasPrefix("to:") || $0.hasPrefix("an:") || $0.hasPrefix("para:") }
        return hasSent && hasTo
    }
}
