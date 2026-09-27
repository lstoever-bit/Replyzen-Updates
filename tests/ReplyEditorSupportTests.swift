import Foundation

@main struct ReplyEditorSupportTests {
    static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), label); checks += 1
        }
        func read(_ direct: String?, _ count: Int?, _ ranged: String?, _ nested: String?) -> String? {
            ReplyEditorSupport.readText(value: { direct }, characterCount: { count },
                rangeText: { _ in ranged }, descendants: { nested })
        }
        let unicode = "Hallo M\u{00FC}ller \u{1F44D}\nOriginal"
        check(read(nil, unicode.utf16.count, unicode, nil) == unicode, "range-only HTML editor")
        check(read("", unicode.utf16.count, unicode, nil) == unicode, "empty AXValue does not mask range")
        check(read("part", unicode.utf16.count, unicode, nil) == unicode, "partial AXValue does not mask range")
        check(read(unicode, nil, nil, nil) == unicode, "normal direct value")
        check(read(nil, nil, nil, unicode) == unicode, "readable descendants")
        check(read("", nil, nil, unicode) == unicode, "empty WebArea with populated children")
        check(read(nil, 0, nil, nil) == "", "explicitly empty editor")
        check(read(nil, nil, nil, nil) == nil, "unknown is not empty")
        check(read("", 5, nil, nil) == nil, "unreadable nonempty editor stays unknown")
        check(read(nil, 9, "short", nil) == nil, "partial range rejected")
        check(read(nil, 9, nil, "short") == nil, "partial descendant scan rejected")
        check(read(nil, 1_000_001, "a", "b") == nil, "oversized range rejected")
        var requested: NSRange?
        let result = ReplyEditorSupport.readText(value: { nil }, characterCount: { unicode.utf16.count },
            rangeText: { requested = $0; return unicode }, descendants: { nil })
        check(result == unicode && requested == NSRange(location: 0, length: unicode.utf16.count), "uses UTF16 range including emoji")
        let graph = [0: [1, 2], 1: [3], 2: [3], 3: [0]]
        let visited = ReplyEditorSupport.nodes(root: 0, children: { graph[$0] ?? [] }, hash: { _ in 42 }, equal: ==)
        check(visited == [0, 1, 3, 2], "all hash collisions preserved and graph cycles stopped")
        check(ReplyEditorSupport.nodes(root: 0, maximum: 2, children: { graph[$0] ?? [] }, hash: { _ in 0 }, equal: ==) == nil, "bounded traversal fails closed")
        for (label, key, mods) in [("Paste", "v", 0), ("Einsetzen", "V", 0), ("Coller", "v", 0)] {
            check(ReplyEditorSupport.isStandardPaste(title: label, key: key, modifiers: mods), "command paste")
        }
        for label in ["Paste", "Einsetzen", "Einf\u{00FC}gen", "Pegar"] {
            check(ReplyEditorSupport.isStandardPaste(title: label, key: nil, modifiers: nil), "exact localized paste")
        }
        for mods in [1, 2, 4, 8, 3, 7] {
            check(!ReplyEditorSupport.isStandardPaste(title: "Paste", key: "v", modifiers: mods), "nonstandard shortcut rejected")
        }
        check(!ReplyEditorSupport.isStandardPaste(title: "Paste", key: "v", modifiers: nil), "unknown modifiers not guessed")
        for label in ["Paste Special", "Paste and Match Style", "Send", "Paste as Quotation", "Einsetzen und Stil anpassen"] {
            check(!ReplyEditorSupport.isStandardPaste(title: label, key: nil, modifiers: nil), "other menu items rejected")
        }
        print("PASS: \(checks) Reply editor compatibility checks; no live Outlook")
    }
}
