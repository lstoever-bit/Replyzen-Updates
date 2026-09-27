import Foundation

struct MailWritingPrompt: Equatable {
    let system: String
    let user: String

    var previewText: String {
        "SYSTEM PROMPT:\n\n\(system)\n\nUSER PROMPT:\n\n\(user)"
    }
}

enum MailPromptBuilder {
    static let systemPrompt = """
You are an email writing assistant.

Generate the requested email text strictly based on the user's instruction and the provided email context.

Rules:
- Follow the requested language.
- Follow the requested tone.
- If compact is true, keep the result short and concise.
- If compact is false, use a natural amount of detail.
- Do not invent facts, names, dates, commitments or explanations.
- Use the email thread only as context.
- Do not explain what you are doing.
- Return only the final text for the email editor.
"""

    static func make(payload: ChatGPTTransferPayload, newMail: Bool = false) -> MailWritingPrompt {
        let context = payload.mailThread ?? ""
        let compact = payload.compact ? "true" : "false"
        var lines = [
            "Language: \(payload.language)",
            "Tone: \(payload.tone)",
            "Compact: \(compact)",
            "",
            "Email context:"
        ]
        if !context.isEmpty {
            lines.append(context)
        }
        lines.append("")
        lines.append("User instruction:")
        lines.append(payload.userText)
        let userPrompt = lines.joined(separator: "\n")
        let rules = newMail ? systemPrompt.replacingOccurrences(
            of: "- Return only the final text for the email editor.",
            with: "- Return a JSON object with subject, body and html. Always provide a short non-empty subject in the requested language based only on the user's instruction. Put only the message text in body, without the subject. Put the same body in email-safe HTML in html, or use an empty html string.") : systemPrompt
        return MailWritingPrompt(system: rules, user: userPrompt)
    }
}
