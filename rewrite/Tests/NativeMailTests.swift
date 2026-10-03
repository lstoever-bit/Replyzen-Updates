import Foundation

final class FakeOutlook: NativeOutlookTransport {
    var calls: [String] = []
    var failAt: String?
    var before: NativeDraftSnapshot
    var after: NativeDraftSnapshot
    var capturedSource: NativeMessageToken?
    var sourceFiles: [NativeAttachment] = []
    var appliedHTML = ""
    init(before: NativeDraftSnapshot, after: NativeDraftSnapshot) { self.before = before; self.after = after }
    func step(_ name: String) throws { calls.append(name); if failAt == name { throw NativeMailError.transport(code: -1712) } }
    func capture() throws -> NativeMailContext { throw NativeMailError.missingSource }
    func validateSource(_ token: NativeMessageToken) throws { try step("validate"); capturedSource = token }
    func sourceAttachments(_ token: NativeMessageToken) throws -> [NativeAttachment] { try step("sourceAttachments"); return sourceFiles }
    func create(mode: NativeMailMode, source: NativeMessageToken?) throws -> String { try step("create:\(mode.rawValue)"); return before.id }
    func readDraft(id: String) throws -> NativeDraftSnapshot { try step("read"); return appliedHTML.isEmpty ? before : after }
    func apply(id: String, expected: NativeDraftSnapshot, subject: String, html: String, reminderBCC: String?) throws {
        try step("apply"); appliedHTML = html
    }
    func reveal(id: String) throws { try step("reveal") }
}

@main struct NativeMailTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name); checks += 1
        }
        func fails(_ name: String, _ operation: () throws -> Void) {
            do { try operation(); fatalError("Expected failure: \(name)") } catch { checks += 1 }
        }
        let token = NativeMessageToken(localID: "10", internetID: "Message-ID: <test@invalid>", subject: "Original")
        let note = "Hallo,\n\nvielen Dank! \u{1F44D}"
        let originals = ["quoted original", "", "a \u{1F642} b\r\nmore"]
        let inventories: [[NativeAttachment]] = [[], [.init(name: "a.pdf", size: 4)], [.init(name: "a.pdf", size: 4), .init(name: "a.pdf", size: 4)], [.init(name: "inline.png", size: 200), .init(name: "a.pdf", size: 4)]]
        for mode in NativeMailMode.allCases {
            for original in originals {
                for files in inventories {
                    let before = NativeDraftSnapshot(id: "20", subject: mode == .newMail ? "" : "Re: Original", html: "<html><head><style>x</style></head><body><img src='cid:picture'>\(original)</body></html>", plainText: original, attachments: files, isHTML: true)
                    let subject = mode == .newMail ? "Betreff" : before.subject
                    let after = NativeDraftSnapshot(id: "20", subject: subject, html: "", plainText: note + "\n\n" + original, attachments: files, isHTML: true)
                    let fake = FakeOutlook(before: before, after: after)
                    if mode == .forward { fake.sourceFiles = files }
                    let request = NativeMailRequest(operationID: UUID(), mode: mode, source: mode == .newMail ? nil : token, subject: "Betreff", note: note, noteHTML: "", reminderBCC: nil)
                    let transaction = NativeMailTransaction(transport: fake)
                    let id = try transaction.run(request)
                    check(id == "20", "native ID returned")
                    check(fake.calls.filter { $0.hasPrefix("create:") }.count == 1, "create once")
                    check(fake.calls.filter { $0 == "apply" }.count == 1, "apply once")
                    check(fake.appliedHTML.contains("src='cid:picture'"), "inline CID preserved")
                    check(fake.appliedHTML.contains(before.html.replacingOccurrences(of: "<body>", with: "<body>")) == false, "new text inserted inside original body")
                    check(mode == .newMail || fake.capturedSource == token, "selection pinned")
                    _ = try transaction.run(request)
                    check(fake.calls.filter { $0.hasPrefix("create:") }.count == 1, "same operation never duplicates draft")
                    check(fake.calls.filter { $0 == "apply" }.count == 1, "same operation never duplicates note")
                }
            }
        }
        let before = NativeDraftSnapshot(id: "20", subject: "Re: Original", html: "", plainText: "Original text", attachments: [.init(name: "test.pdf", size: 5)], isHTML: false)
        let after = NativeDraftSnapshot(id: "20", subject: "Re: Original", html: "", plainText: note + "\nOriginal text", attachments: before.attachments, isHTML: true)
        let request = NativeMailRequest(operationID: UUID(), mode: .reply, source: token, subject: "", note: note, noteHTML: "", reminderBCC: nil)
        for stage in ["create:reply", "read", "apply", "reveal"] {
            let fake = FakeOutlook(before: before, after: after)
            fake.failAt = stage
            let transaction = NativeMailTransaction(transport: fake)
            fails("uncertain \(stage)") { _ = try transaction.run(request) }
            fake.failAt = nil
            if case .complete = transaction.state { _ = try transaction.run(request) }
            else { fails("do not replay \(stage)") { _ = try transaction.run(request) } }
            check(fake.calls.filter { $0.hasPrefix("create:") }.count == 1, "no duplicate after \(stage)")
        }
        for changed in [
            NativeDraftSnapshot(id: "99", subject: after.subject, html: "", plainText: after.plainText, attachments: after.attachments, isHTML: true),
            NativeDraftSnapshot(id: "20", subject: "wrong", html: "", plainText: after.plainText, attachments: after.attachments, isHTML: true),
            NativeDraftSnapshot(id: "20", subject: after.subject, html: "", plainText: note, attachments: after.attachments, isHTML: true),
            NativeDraftSnapshot(id: "20", subject: after.subject, html: "", plainText: after.plainText, attachments: [], isHTML: true),
            NativeDraftSnapshot(id: "20", subject: after.subject, html: "", plainText: "Original text", attachments: after.attachments, isHTML: true)
        ] {
            check(!NativeMailComposition.verify(note: note, subject: after.subject, before: before, after: changed), "corrupted output rejected")
        }
        let fwd = FakeOutlook(before: before, after: after)
        fwd.sourceFiles = before.attachments + [.init(name: "missing.bin", size: 18)]
        let forwardRequest = NativeMailRequest(operationID: UUID(), mode: .forward, source: token, subject: "", note: note, noteHTML: "", reminderBCC: nil)
        fails("native forward lost attachment") { _ = try NativeMailTransaction(transport: fwd).run(forwardRequest) }
        check(!fwd.calls.contains("apply"), "lost attachment stops before modification")
        check(NativeMailComposition.subject(" \n ", note: "Hallo Max,\n\nUnser Termin am Montag") == "Unser Termin am Montag", "missing subject recovered")
        check(NativeMailComposition.subject("Existing", note: note) == "Existing", "existing subject retained")
        let escaped = NativeMailComposition.prepend(note: "<script>bad()</script>\n\"quotes\"", html: "", to: before, operationID: UUID())
        check(!escaped.contains("<script>"), "plain text escaped")
        check(escaped.contains("&lt;script&gt;"), "escape preserves literal text")
        check(escaped.contains("Original text"), "plain original retained")
        let htmlFragment = NativeMailComposition.fragment("<html><head></head><body><p><strong>Hi</strong></p></body></html>", fallback: "Hi")
        check(htmlFragment == "<p><strong>Hi</strong></p>", "formatting retained without nested documents")
        print("PASS: \(checks) native transaction/composition checks; no live mailbox claimed")
    }
}
