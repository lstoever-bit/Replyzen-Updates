import Foundation

/// The complete user-data payload sent to OpenAI for mail drafting.
/// Keep this intentionally small: no hidden app state, recipients or unrelated metadata.
struct ChatGPTTransferPayload: Equatable {
    let action: String
    let mailThread: String?
    let userText: String
    let userHTML: String?
    let tone: String
    let language: String
    let compact: Bool

    var apiJSON: String {
        var object: [String: Any] = [
            "action": action,
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
