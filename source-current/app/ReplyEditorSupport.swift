import Foundation

/// Compatibility algorithms shared by the real Reply AX adapter and its tests.
/// Does not contain or log any mail content.
enum ReplyEditorSupport {
    static let maximumTextLength = 1_000_000

    static func readText(value: () -> String?, characterCount: () -> Int?,
                         rangeText: (NSRange) -> String?, descendants: () -> String?) -> String? {
        let direct = value()
        let count = characterCount()
        // AXWebArea can expose an empty or partial AXValue while the native text
        // interface exposes the complete HTML editor. Range lengths are UTF-16.
        if let direct, !direct.isEmpty, count == nil || direct.utf16.count == count { return direct }
        if let count, count > 0 {
            guard count <= maximumTextLength else { return nil }
            if let ranged = rangeText(NSRange(location: 0, length: count)), ranged.utf16.count == count {
                return ranged
            }
        }
        if let nested = descendants(), !nested.isEmpty {
            if let count, count > nested.utf16.count { return nil }
            return nested
        }
        // A known positive length with no readable text must NOT become an empty
        // baseline. That would permit pasting again on an unverifiable draft.
        if let count, count > 0 { return nil }
        if count == 0 { return "" }
        return direct
    }

    static func nodes<Node>(root: Node, maximum: Int = 12_000,
                            children: (Node) -> [Node], hash: (Node) -> UInt,
                            equal: (Node, Node) -> Bool) -> [Node]? {
        var stack = [root], result: [Node] = []
        var buckets: [UInt: [Node]] = [:]
        while let node = stack.popLast() {
            let key = hash(node)
            let bucket = buckets[key] ?? []
            // CFHash is not an identity. Different AX objects may collide.
            if bucket.contains(where: { equal($0, node) }) { continue }
            guard result.count < maximum else { return nil }
            buckets[key, default: []].append(node)
            result.append(node)
            stack.append(contentsOf: children(node).reversed())
        }
        return result
    }

    static func isStandardPaste(title: String, key: String?, modifiers: Int?) -> Bool {
        let label = title.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // AX uses 0 for command-only; Shift/Option/Control/NoCommand have bits.
        // Never select Paste Special, Paste and Match Style or Paste as Quotation.
        if let key, !key.isEmpty {
            return key.lowercased() == "v" && modifiers == 0
        }
        return ["paste", "einsetzen", "einfugen", "pegar"].contains(label)
    }
}
