import AppKit

@main struct ReplyPreparedPayloadTests {
    static func main() {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let plain = "Hallo M\u{00fc}ller,\nDanke! \u{1f44d}\n\n"
        let rich = "<p>Hallo M\u{00fc}ller,<br><strong>Danke!</strong> \u{1f44d}</p><br><br>"
        // Preparation is allowed to use AppKit's importer before the handoff.
        let prepared = MailTypography.payload(plainText: plain, html: rich)
        var runLoopAdvanced = false
        DispatchQueue.main.async { runLoopAdvanced = true }
        MailTypography.write(prepared, to: board)
        precondition(!runLoopAdvanced, "Writing a prepared payload must not spin the main run loop")
        precondition(board.string(forType: .string) == plain)
        precondition(board.string(forType: .html) == prepared.html)
        precondition(board.data(forType: .rtf) == prepared.rtf)
        precondition(prepared.html.contains("10.5pt"))
        // Reusing the immutable payload must be a byte-preserving clipboard write.
        MailTypography.write(prepared, to: board)
        precondition(!runLoopAdvanced)
        precondition(board.string(forType: .html) == prepared.html)
        precondition(board.data(forType: .rtf) == prepared.rtf)
        print("PASS: real AppKit prepared payload write preserves plain/HTML/RTF and does not advance the main run loop; no Outlook involved")
    }
}
