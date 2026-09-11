import Foundation

@main
struct ChatGPTTransferPayloadTests {
    static func main() {
        let exactInstruction = "  schreibe ein gedicht\nmit zwei Strophen  "
        let reply = ChatGPTTransferPayload(
            mailThread: "Incoming mail thread",
            userText: exactInstruction,
            tone: "professional",
            language: "en-US",
            compact: false
        )
        let prompt = MailPromptBuilder.make(payload: reply)
        precondition(prompt.system == MailPromptBuilder.systemPrompt)
        precondition(prompt.system.contains("You are an email writing assistant."))
        precondition(prompt.system.contains("Do not invent facts, names, dates, commitments or explanations."))
        precondition(prompt.user.contains("Language: en-US"))
        precondition(prompt.user.contains("Tone: professional"))
        precondition(prompt.user.contains("Compact: false"))
        precondition(prompt.user.contains("Email context:\nIncoming mail thread"))
        precondition(prompt.user.hasSuffix("User instruction:\n" + exactInstruction))
        precondition(!prompt.user.lowercased().contains("user_html"))
        precondition(!prompt.user.lowercased().contains("<html"))

        let newMail = ChatGPTTransferPayload(
            mailThread: nil,
            userText: "Invite Stefan for lunch.",
            tone: "friendly",
            language: "de",
            compact: true
        )
        let newPrompt = MailPromptBuilder.make(payload: newMail)
        precondition(newPrompt.user.contains("Language: de"))
        precondition(newPrompt.user.contains("Tone: friendly"))
        precondition(newPrompt.user.contains("Compact: true"))
        precondition(newPrompt.user.contains("Email context:\n\nUser instruction:\nInvite Stefan for lunch."))
        precondition(newPrompt.previewText.contains("SYSTEM PROMPT:"))
        precondition(newPrompt.previewText.contains("USER PROMPT:"))
        print("PASS: central mail prompt preserves user_text and sends only requested context/settings")
    }
}
