// Appended to OpenAIClient.swift by run-tests.sh to exercise private decoders.
extension OpenAIClient {
    static func runDecoderChecks() throws {
        let reply = try decodeReplyDraft("{\"body\":\"Hello\",\"html\":\"<p>Hello</p>\"}")
        precondition(reply.body == "Hello" && reply.html == "<p>Hello</p>")
        let fenced = try decodeReplyDraft("```json\n{\"body\":\"Hallo\",\"html\":null}\n```")
        precondition(fenced.body == "Hallo" && fenced.html == nil)
        let newMail = try decodeNewMailDraft("{\"subject\":\"Test\",\"body\":\"Hello\",\"html\":null}")
        precondition(newMail.subject == "Test" && newMail.body == "Hello")
        // Exercise the actual decoder, not just a source-string contract.
        let retainedBody = "Hallo Max,\n\nBitte bestaetige den Liefertermin."
        let retainedHTML = "<p>Hallo Max,</p><p>Bitte bestaetige den Liefertermin.</p>"
        for subject in [NSNull(), "", " \n\t"] as [Any] {
            let data = try JSONSerialization.data(withJSONObject: ["subject": subject, "body": retainedBody, "html": retainedHTML])
            let result = try decodeNewMailDraft(String(decoding: data, as: UTF8.self))
            precondition(result.subject == "Bitte bestaetige den Liefertermin")
            precondition(result.body == retainedBody && result.html == retainedHTML)
        }
        let missingData = try JSONSerialization.data(withJSONObject: ["body": retainedBody, "html": retainedHTML])
        let recovered = try decodeNewMailDraft(String(decoding: missingData, as: UTF8.self))
        precondition(!recovered.subject.isEmpty && recovered.body == retainedBody)
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
