import Foundation
@main struct RecoveryTests {
    static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            precondition(value(), name); checks += 1
        }
        check(ReplyRecoveryRules.activation(outlookActive: false, replyzenActive: true, frontmostKnown: true, attempt: 0) == .request, "yield before first activation")
        for tick in 1..<20 {
            check(ReplyRecoveryRules.activation(outlookActive: false, replyzenActive: true, frontmostKnown: true, attempt: tick) == .request, "asynchronous activation may take several polls")
        }
        check(ReplyRecoveryRules.activation(outlookActive: true, replyzenActive: false, frontmostKnown: true, attempt: 5) == .ready, "continue only when Outlook is active")
        check(ReplyRecoveryRules.activation(outlookActive: false, replyzenActive: false, frontmostKnown: true, attempt: 1) == .abort, "user switched to another app")
        check(ReplyRecoveryRules.activation(outlookActive: false, replyzenActive: false, frontmostKnown: false, attempt: 1) == .wait, "transient unknown activation")
        check(ReplyRecoveryRules.activation(outlookActive: false, replyzenActive: true, frontmostKnown: true, attempt: 20) == .abort, "bounded activation")
        check(ReplyRecoveryRules.focusStep(attempt: 1) == .accessibility, "first focus request")
        check(ReplyRecoveryRules.focusStep(attempt: 2) == .press, "restore native AXPress fallback")
        check(ReplyRecoveryRules.focusStep(attempt: 3) == .subjectTab, "restore verified subject-to-body navigation")
        check(ReplyRecoveryRules.focusStep(attempt: 4) == .click, "hit-tested click last")
        check(ReplyRecoveryRules.hasFocus(active: true, sameWindow: true, reportsEditor: false, editorMarkedFocused: true, reportsOtherField: false), "exact editor focus with wrapper report")
        check(!ReplyRecoveryRules.hasFocus(active: true, sameWindow: true, reportsEditor: false, editorMarkedFocused: false, reportsOtherField: false), "container alone not focus")
        check(!ReplyRecoveryRules.hasFocus(active: true, sameWindow: true, reportsEditor: true, editorMarkedFocused: true, reportsOtherField: true), "other field blocks stale focus")
        check(!ReplyRecoveryRules.hasFocus(active: false, sameWindow: true, reportsEditor: true, editorMarkedFocused: true, reportsOtherField: false), "inactive app blocks paste")
        check(!ReplyRecoveryRules.hasFocus(active: true, sameWindow: false, reportsEditor: true, editorMarkedFocused: true, reportsOtherField: false), "wrong window blocks paste")
        let body = "Hallo Herr M\u{00FC}ller,\n\nBitte best\u{00E4}tigen Sie den Termin am Dienstag.\n\nViele Gr\u{00FC}\u{00DF}e\nLennard"
        for subject in [nil, "", " \n\t", "\u{200B}"] as [String?] {
            check(NewMailSubject.resolve(subject, body: body, language: "de") == "Bitte best\u{00E4}tigen Sie den Termin am Dienstag", "blank subject is recoverable")
        }
        check(NewMailSubject.resolve("Liefertermin", body: body, language: "de") == "Liefertermin", "retain provided subject")
        check(NewMailSubject.resolve(nil, body: "Hi Jane,\nPlease send the report.\nBest regards", language: "en-US") == "Please send the report", "English extraction")
        check(NewMailSubject.resolve(nil, body: "Hola Juan,\nConfirma la fecha de entrega.\nSaludos", language: "es") == "Confirma la fecha de entrega", "Spanish extraction")
        check(NewMailSubject.resolve(nil, body: "Hallo Max, bitte ruf mich an.", language: "de") == "bitte ruf mich an", "single-line greeting")
        check(NewMailSubject.resolve(nil, body: "Hi Jane,", language: "en-US") == "Message", "fallback language")
        check(NewMailSubject.resolve(nil, body: "Hola Juan,", language: "es") == "Mensaje", "Spanish fallback language")
        check(NewMailSubject.resolve(nil, body: String(repeating: "\u{1F44D} ", count: 200), language: "de").count <= 100, "bounded Unicode subject")
        check(!NewMailSubject.resolve("Termin\r\nBcc: nobody", body: body, language: "de").contains("\n"), "single-line subject")
        let payload = ChatGPTTransferPayload(mailThread: nil, userText: "Please ask for the report.", tone: "friendly", language: "en-US", compact: true)
        let reply = MailPromptBuilder.make(payload: payload)
        let newMail = MailPromptBuilder.make(payload: payload, newMail: true)
        check(reply.system == MailPromptBuilder.systemPrompt, "Reply prompt unchanged")
        check(newMail.system.contains("non-empty subject"), "New Mail explicitly requests a subject")
        check(!newMail.system.contains("Return only the final text for the email editor"), "remove conflicting output instruction only for New Mail")
        check(newMail.user == reply.user, "preserve user input and selected settings")
        check(newMail.previewText.contains(newMail.system), "preview displays actual new-mail system prompt")
        print("PASS: \(checks) focus handoff, subject recovery and prompt checks (no live Outlook)")
    }
}
