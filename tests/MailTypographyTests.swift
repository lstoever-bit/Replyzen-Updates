import AppKit

@main
struct MailTypographyChecks {
    static func checkFonts(_ text: NSAttributedString) {
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            guard let font = value as? NSFont else { fatalError("Missing font") }
            precondition(abs(font.pointSize - 10.5) < 0.001, "Incorrect point size: \(font.pointSize)")
        }
    }

    static func main() throws {
        _ = NSApplication.shared
        precondition(Thread.isMainThread)
        precondition(MailTypography.family == "Calibri Light")
        precondition(MailTypography.baseFont.pointSize == 10.5)
        let plain = "Hallo <Team> & Freunde\nGr\u{00FC}\u{00DF}e \u{1F44B}\n\n"
        let payload = MailTypography.payload(plainText: plain, html: "")
        precondition(payload.plainText == plain)
        precondition(payload.html.contains("Calibri Light") && payload.html.contains("font-size: 10.5pt;"))
        precondition(payload.html.contains("&lt;Team&gt;") && payload.html.contains("&amp;"))
        precondition(!payload.html.contains("<style"), "Global CSS could affect a signature")
        precondition(!payload.html.contains("class=\""), "Cocoa classes must be inlined")
        checkFonts(MailTypography.attributedString(plainText: plain, html: ""))

        let rich = "<p style=\"font-family: Courier; font-size: 24pt\">Normal <strong>Bold</strong> <em>Italic</em> <u>Underline</u></p><ul><li>One</li><li>Two</li></ul>"
        let imported = MailTypography.attributedString(plainText: "Normal Bold Italic Underline\nOne\nTwo", html: rich)
        checkFonts(imported)
        let manager = NSFontManager.shared
        for (word, trait) in [("Bold", NSFontTraitMask.boldFontMask), ("Italic", NSFontTraitMask.italicFontMask)] {
            let range = (imported.string as NSString).range(of: word)
            let font = imported.attribute(.font, at: range.location, effectiveRange: nil) as! NSFont
            precondition(manager.traits(of: font).contains(trait), "Lost \(word) formatting")
        }
        let output = MailTypography.htmlDocument(from: imported)
        precondition(output.contains("<ul") || output.contains("One"))
        precondition(!output.contains("<style") && !output.contains("class=\""))
        let roundtrip = MailTypography.attributedString(plainText: imported.string, html: output)
        checkFonts(roundtrip)
        for (word, trait) in [("Bold", NSFontTraitMask.boldFontMask), ("Italic", NSFontTraitMask.italicFontMask)] {
            let range = (roundtrip.string as NSString).range(of: word)
            precondition(range.location != NSNotFound)
            let font = roundtrip.attribute(.font, at: range.location, effectiveRange: nil) as! NSFont
            precondition(manager.traits(of: font).contains(trait), "HTML roundtrip lost \(word)")
        }
        let underlineRange = (roundtrip.string as NSString).range(of: "Underline")
        precondition((roundtrip.attribute(.underlineStyle, at: underlineRange.location, effectiveRange: nil) as? NSNumber)?.intValue != 0)

        // A full Cocoa editor document must retain styling after conversion, too.
        let editorHTML = try imported.data(from: NSRange(location: 0, length: imported.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
        let editorPayload = MailTypography.payload(plainText: imported.string, html: String(decoding: editorHTML, as: UTF8.self))
        precondition(editorPayload.html.contains("font-size: 10.5pt;"))
        precondition(!editorPayload.html.contains("<style"))

        let forwarded = MailTypography.attributedString(plainText: "Note\n\n", html: "<p>Note</p><br><br>")
        precondition(forwarded.string == "Note\n\n", "Forward separators changed")
        let reset = NSMutableAttributedString(string: "Reset", attributes: [.font: NSFont.systemFont(ofSize: 30)])
        MailTypography.normalizeFonts(in: reset)
        checkFonts(reset)

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        MailTypography.write(plainText: plain, html: "", to: board)
        precondition(board.string(forType: .string) == plain)
        precondition(board.string(forType: .html)?.contains("font-size: 10.5pt;") == true)
        if MailTypography.installedFont != nil {
            guard let rtf = board.data(forType: .rtf) else { fatalError("Missing matching RTF") }
            let restored = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            checkFonts(restored)
            precondition(String(decoding: rtf, as: UTF8.self).contains("\\fs21"))
        } else {
            precondition(board.data(forType: .rtf) == nil, "Do not prefer substitute-font RTF over Calibri HTML")
        }
        print("PASS: Calibri Light 10.5 pt, inline HTML, rich/empty-HTML paths, editor roundtrip, bold/italic/underline, forward spacing, pasteboard")
    }
}
