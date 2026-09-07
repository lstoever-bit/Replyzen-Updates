import AppKit

/// One typography policy for the editor and the text handed to Outlook.
/// This formats only ReplyZen's new text, never the existing Outlook document.
enum MailTypography {
    static let family = "Calibri Light"
    static let pointSize: CGFloat = 10.5
    static let inlineFont = "font-family: 'Calibri Light', Calibri, sans-serif; font-size: 10.5pt;"

    // Do not bundle Microsoft font files. HTML names the requested face even when
    // it is available to Outlook but not registered for this process.
    static let installedFont: NSFont? =
        NSFont(name: "Calibri-Light", size: pointSize) ??
        NSFont(name: "Calibri Light", size: pointSize) ??
        NSFont(name: "CalibriLight", size: pointSize)
    static let baseFont: NSFont = installedFont ?? NSFont.systemFont(ofSize: pointSize, weight: .light)

    private static let fonts: [Int: NSFont] = {
        let manager = NSFontManager.shared
        var result: [Int: NSFont] = [0: baseFont]
        result[1] = manager.convert(baseFont, toHaveTrait: .boldFontMask)
        result[2] = manager.convert(baseFont, toHaveTrait: .italicFontMask)
        result[3] = manager.convert(result[1]!, toHaveTrait: .italicFontMask)
        return result
    }()

    static func font(preserving source: NSFont?) -> NSFont {
        let traits = source.map { NSFontManager.shared.traits(of: $0) } ?? []
        let key = (traits.contains(.boldFontMask) ? 1 : 0) + (traits.contains(.italicFontMask) ? 2 : 0)
        return fonts[key] ?? baseFont
    }

    static func normalizeFonts(in text: NSMutableAttributedString) {
        guard text.length > 0 else { return }
        var changes: [(NSRange, NSFont)] = []
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let old = value as? NSFont
            let desired = font(preserving: old)
            if old?.fontName != desired.fontName || old?.pointSize != pointSize {
                changes.append((range, desired))
            }
        }
        guard !changes.isEmpty else { return }
        text.beginEditing()
        for (range, desired) in changes { text.addAttribute(.font, value: desired, range: range) }
        text.endEditing()
    }

    static func attributedString(plainText: String, html: String) -> NSAttributedString {
        precondition(Thread.isMainThread, "AppKit HTML import must run on the main thread")
        let result: NSMutableAttributedString
        if !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let data = html.data(using: .utf8),
           let imported = try? NSAttributedString(data: data, options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
           ], documentAttributes: nil),
           imported.length > 0 {
            result = NSMutableAttributedString(attributedString: imported)
            // HTML paragraph import adds a terminal newline. Match the caller's
            // leading/trailing newlines when the actual text is otherwise equal.
            // This also keeps the two blank lines before a forwarded thread.
            let core = imported.string.trimmingCharacters(in: .newlines)
            if !core.isEmpty && core == plainText.trimmingCharacters(in: .newlines) {
                let sourceRange = (imported.string as NSString).range(of: core)
                let targetRange = (plainText as NSString).range(of: core)
                let aligned = NSMutableAttributedString(string: (plainText as NSString).substring(to: targetRange.location), attributes: [.font: baseFont])
                aligned.append(imported.attributedSubstring(from: sourceRange))
                aligned.append(NSAttributedString(string: (plainText as NSString).substring(from: NSMaxRange(targetRange)), attributes: [.font: baseFont]))
                result.setAttributedString(aligned)
            }
        } else {
            result = NSMutableAttributedString(string: plainText, attributes: [.font: baseFont])
        }
        normalizeFonts(in: result)
        return result
    }

    struct Payload {
        let plainText: String
        let html: String
        let rtf: Data?
    }

    static func payload(plainText: String, html: String) -> Payload {
        let attributed = attributedString(plainText: plainText, html: html)
        let richHTML = htmlDocument(from: attributed)
        // Never offer an RTF representation in a substituted system font: Outlook
        // may prefer it over the correctly styled HTML. With Calibri Light locally
        // available, both rich pasteboard representations use the same 10.5 pt font.
        let rtf: Data? = installedFont == nil ? nil : try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        return Payload(plainText: plainText, html: richHTML, rtf: rtf)
    }

    static func write(plainText: String, html: String, to pasteboard: NSPasteboard = .general) {
        let value = payload(plainText: plainText, html: html)
        let item = NSPasteboardItem()
        item.setString(value.plainText, forType: .string)
        item.setString(value.html, forType: .html)
        if let rtf = value.rtf { item.setData(rtf, forType: .rtf) }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// Convert Cocoa's class-based HTML to a self-contained inline-styled fragment.
    /// No global p/span stylesheet may leak into an existing Outlook signature.
    static func htmlDocument(from attributed: NSAttributedString) -> String {
        let normalized = NSMutableAttributedString(attributedString: attributed)
        normalizeFonts(in: normalized)
        var fragment = escapeHTML(normalized.string).replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "<br>")
        if let data = try? normalized.data(from: NSRange(location: 0, length: normalized.length), documentAttributes: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]), let exported = String(data: data, encoding: .utf8),
           let body = firstMatch(#"(?is)<body\b[^>]*>(.*?)</body>"#, in: exported) {
            var rules: [String: String] = [:]
            for match in matches(#"(?is)([a-z][a-z0-9]*)(?:\.([a-z0-9_-]+))?\s*\{([^{}]*)\}"#, in: exported) {
                let text = exported as NSString
                let tag = text.substring(with: match.range(at: 1)).lowercased()
                let classRange = match.range(at: 2)
                let key = classRange.location == NSNotFound ? tag : tag + "." + text.substring(with: classRange)
                rules[key] = text.substring(with: match.range(at: 3))
            }
            fragment = body
            let original = fragment as NSString
            for match in matches(#"(?is)<([a-z][a-z0-9]*)(\s[^<>]*?)?\s*/?>"#, in: fragment).reversed() {
                let tag = original.substring(with: match.range(at: 1)).lowercased()
                if tag == "br" || tag == "hr" { continue }
                var attributes = match.range(at: 2).location == NSNotFound ? "" : original.substring(with: match.range(at: 2))
                var styles = [rules[tag] ?? ""]
                if let classes = firstMatch(#"(?is)\bclass\s*=\s*["']([^"']*)["']"#, in: attributes) {
                    for name in classes.split(whereSeparator: { $0.isWhitespace }) {
                        styles.append(rules[tag + "." + name] ?? "")
                    }
                }
                if let existing = firstMatch(#"(?is)\bstyle\s*=\s*["'](.*?)["'](?=\s|$)"#, in: attributes) {
                    styles.append(existing)
                }
                attributes = replacing(#"(?is)\s+(?:class|style)\s*=\s*"[^"]*""#, in: attributes, with: "")
                attributes = replacing(#"(?is)\s+(?:class|style)\s*=\s*'[^']*'"#, in: attributes, with: "")
                styles.append(inlineFont)
                let css = styles.filter { !$0.isEmpty }.joined(separator: "; ")
                    .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                let replacement = "<\(tag)\(attributes) style=\"\(escapeHTML(css))\">"
                fragment = (fragment as NSString).replacingCharacters(in: match.range, with: replacement)
            }
        }
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>" +
            "<div style=\"\(inlineFont)\">\(fragment)</div></body></html>"
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func matches(_ pattern: String, in value: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: value, range: NSRange(location: 0, length: (value as NSString).length))
    }

    private static func firstMatch(_ pattern: String, in value: String) -> String? {
        guard let match = matches(pattern, in: value).first, match.numberOfRanges > 1 else { return nil }
        return (value as NSString).substring(with: match.range(at: 1))
    }

    private static func replacing(_ pattern: String, in value: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        return regex.stringByReplacingMatches(in: value, range: NSRange(location: 0, length: (value as NSString).length), withTemplate: replacement)
    }
}
