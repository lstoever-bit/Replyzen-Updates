// Appended to OpenAIClient.swift by run-tests.sh to exercise private decoders.
extension OpenAIClient {
    static func runDecoderChecks() throws {
        let reply = try decodeReplyDraft("{\"body\":\"Hello\",\"html\":\"<p>Hello</p>\"}")
        precondition(reply.body == "Hello" && reply.html == "<p>Hello</p>")
        let fenced = try decodeReplyDraft("```json\n{\"body\":\"Hallo\",\"html\":null}\n```")
        precondition(fenced.body == "Hallo" && fenced.html == nil)
        let newMail = try decodeNewMailDraft("{\"subject\":\"Test\",\"body\":\"Hello\",\"html\":null}")
        precondition(newMail.subject == "Test" && newMail.body == "Hello")
        let event = try decodeCalendarSuggestion("{\"title\":\"Test\",\"description\":\"Description\",\"start\":null,\"end\":null,\"confidence\":\"missing\"}")
        precondition(event.start == nil && event.end == nil && event.title == "Test")
        let invalid: [() throws -> Void] = [
            { _ = try decodeReplyDraft("not JSON") },
            { _ = try decodeReplyDraft("{\"body\":\"  \"}") },
            { _ = try decodeNewMailDraft("{\"subject\":\"Test\",\"body\":\"\"}") },
            { _ = try decodeNewMailDraft("{}") },
            { _ = try decodeCalendarSuggestion("{}") }
        ]
        for operation in invalid {
            do { try operation(); fatalError("Expected API error") }
            catch { precondition(error is APIError) }
        }
        let output = Data("{\"output\":[{\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"},{\"type\":\"output_text\",\"text\":\"world\"}]}]}".utf8)
        let outputText = try extractOutputText(from: output)
        precondition(outputText == "Hello\nworld")
        let error = Data("{\"error\":{\"message\":\"Test error\"}}".utf8)
        precondition(extractErrorMessage(from: error) == "Test error")
        precondition(extractErrorMessage(from: Data("{}".utf8)) == nil)
        print("PASS: mail/calendar client decoder and error cases")
    }
}

@main
struct ClientCheckRunner {
    static func main() throws { try OpenAIClient.runDecoderChecks() }
}
