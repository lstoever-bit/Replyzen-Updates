import Foundation

@main
struct ChatGPTTransferPayloadTests {
    static func main() throws {
        let reply = ChatGPTTransferPayload(
            mailThread: "Incoming mail thread",
            userText: "Please confirm Tuesday.",
            userHTML: "<p>Please confirm <strong>Tuesday</strong>.</p>",
            tone: "friendly",
            language: "en-US",
            compact: true
        )
        let replyObject = try decode(reply.apiJSON)
        precondition(Set(replyObject.keys) == ["mail_thread", "user_text", "user_html", "tone", "language", "compact"])
        precondition(replyObject["mail_thread"] as? String == "Incoming mail thread")
        precondition(replyObject["user_text"] as? String == "Please confirm Tuesday.")
        precondition(replyObject["tone"] as? String == "friendly")
        precondition(replyObject["language"] as? String == "en-US")
        precondition(replyObject["compact"] as? Bool == true)
        precondition(replyObject["action"] == nil)

        let newMail = ChatGPTTransferPayload(
            mailThread: nil,
            userText: "Invite Stefan for lunch.",
            userHTML: nil,
            tone: "professional",
            language: "de",
            compact: false
        )
        let newObject = try decode(newMail.apiJSON)
        precondition(Set(newObject.keys) == ["user_text", "tone", "language", "compact"])
        precondition(newObject["mail_thread"] == nil)
        precondition(newObject["user_html"] == nil)
        precondition(newObject["action"] == nil)
        print("PASS: ChatGPT payload contains exactly the allowed user data fields")
    }

    private static func decode(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ReplyZenTests", code: 1)
        }
        return object
    }
}
