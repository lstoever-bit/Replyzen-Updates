import Foundation

/// The complete user-data payload sent to OpenAI for mail drafting.
/// Intentionally contains only the mail context (when applicable), the user's
/// written content/formatting, and the three selected generation settings.
struct ChatGPTTransferPayload: Equatable {
    let mailThread: String?
    let userText: String
    let userHTML: String?
    let tone: String
    let language: String
    let compact: Bool

    var apiJSON: String {
        var object: [String: Any] = [
            "user_text": userText,
            "tone": tone,
            "language": language,
            "compact": compact
        ]
        if let mailThread, !mailThread.isEmpty { object["mail_thread"] = mailThread }
        if let userHTML, !userHTML.isEmpty { object["user_html"] = userHTML }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
