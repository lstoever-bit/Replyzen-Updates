import SwiftUI
import AppKit

final class RichTextEditorController: ObservableObject {
    weak var textView: NSTextView?

    func toggleBold() {
        toggleFontTrait(.boldFontMask)
    }

    func toggleItalic() {
        toggleFontTrait(.italicFontMask)
    }

    func toggleBullets() {
        toggleList(style: .bullets)
    }

    func toggleNumbering() {
        toggleList(style: .numbered)
    }

    func clearFormatting() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = effectiveSelection(in: textView)
        guard range.length > 0 else {
            textView.typingAttributes = [.font: MailTypography.baseFont]
            return
        }
        storage.beginEditing()
        storage.removeAttribute(.font, range: range)
        storage.removeAttribute(.foregroundColor, range: range)
        storage.removeAttribute(.backgroundColor, range: range)
        storage.removeAttribute(.underlineStyle, range: range)
        storage.removeAttribute(.strikethroughStyle, range: range)
        storage.addAttribute(.font, value: MailTypography.baseFont, range: range)
        storage.endEditing()
        textView.didChangeText()
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard let textView, let storage = textView.textStorage else { return }
        let selected = textView.selectedRange()
        let manager = NSFontManager.shared

        if selected.length == 0 {
            let current = (textView.typingAttributes[.font] as? NSFont) ?? MailTypography.baseFont
            let hasTrait = manager.traits(of: current).contains(trait)
            let converted = hasTrait
                ? manager.convert(current, toNotHaveTrait: trait)
                : manager.convert(current, toHaveTrait: trait)
            textView.typingAttributes[.font] = converted
            return
        }

        var firstTraitState: Bool?
        storage.enumerateAttribute(.font, in: selected) { value, _, stop in
            let font = (value as? NSFont) ?? MailTypography.baseFont
            firstTraitState = manager.traits(of: font).contains(trait)
            stop.pointee = true
        }
        let removeTrait = firstTraitState ?? false

        storage.beginEditing()
        storage.enumerateAttribute(.font, in: selected) { value, range, _ in
            let font = (value as? NSFont) ?? MailTypography.baseFont
            let converted = removeTrait
                ? manager.convert(font, toNotHaveTrait: trait)
                : manager.convert(font, toHaveTrait: trait)
            storage.addAttribute(.font, value: converted, range: range)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    private enum ListStyle { case bullets, numbered }

    private func toggleList(style: ListStyle) {
        guard let textView, let storage = textView.textStorage else { return }
        let ns = textView.string as NSString
        let selected = effectiveSelection(in: textView)
        let paragraphRange = ns.paragraphRange(for: selected)
        guard paragraphRange.length > 0 else { return }

        var starts: [Int] = []
        var cursor = paragraphRange.location
        let end = NSMaxRange(paragraphRange)
        while cursor < end {
            starts.append(cursor)
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let next = NSMaxRange(line)
            if next <= cursor { break }
            cursor = next
        }

        func existingPrefixLength(at start: Int, in string: NSString) -> Int {
            let remaining = string.substring(from: start)
            if remaining.hasPrefix("• ") { return 2 }
            if remaining.hasPrefix("- ") { return 2 }
            let prefix = String(remaining.prefix(8))
            if let match = prefix.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                return prefix.distance(from: prefix.startIndex, to: match.upperBound)
            }
            return 0
        }

        let shouldRemove: Bool = {
            switch style {
            case .bullets:
                return starts.allSatisfy { (textView.string as NSString).substring(from: $0).hasPrefix("• ") }
            case .numbered:
                return starts.allSatisfy {
                    let prefix = String((textView.string as NSString).substring(from: $0).prefix(8))
                    return prefix.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
                }
            }
        }()

        storage.beginEditing()
        for (reverseIndex, start) in starts.enumerated().reversed() {
            let currentString = storage.string as NSString
            let oldPrefixLength = existingPrefixLength(at: start, in: currentString)
            if oldPrefixLength > 0 {
                storage.deleteCharacters(in: NSRange(location: start, length: oldPrefixLength))
            }
            if !shouldRemove {
                let prefix: String
                switch style {
                case .bullets:
                    prefix = "• "
                case .numbered:
                    prefix = "\(reverseIndex + 1). "
                }
                let attrs: [NSAttributedString.Key: Any]
                if start < storage.length {
                    attrs = storage.attributes(at: start, effectiveRange: nil)
                } else {
                    attrs = [.font: MailTypography.baseFont]
                }
                storage.insert(NSAttributedString(string: prefix, attributes: attrs), at: start)
            }
        }
        storage.endEditing()
        textView.didChangeText()
    }

    private func effectiveSelection(in textView: NSTextView) -> NSRange {
        let selection = textView.selectedRange()
        if selection.length > 0 { return selection }
        let length = (textView.string as NSString).length
        if length == 0 { return NSRange(location: 0, length: 0) }
        let safeLocation = min(selection.location, max(0, length - 1))
        return (textView.string as NSString).paragraphRange(for: NSRange(location: safeLocation, length: 0))
    }
}

struct RichTextMailEditor: View {
    @Binding var plainText: String
    @Binding var html: String
    var height: CGFloat = 176
    var showsHTMLBadge: Bool = true
    @StateObject private var controller = RichTextEditorController()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                formatButton(title: "B", help: "Fett", action: controller.toggleBold)
                    .font(.system(size: 12, weight: .bold))
                formatButton(title: "I", help: "Kursiv", action: controller.toggleItalic)
                    .font(.system(size: 12).italic())

                Divider().frame(height: 18).padding(.horizontal, 2)

                Button(action: controller.toggleBullets) {
                    Image(systemName: "list.bullet")
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Aufzählung")

                Button(action: controller.toggleNumbering) {
                    Image(systemName: "list.number")
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Nummerierte Liste")

                Divider().frame(height: 18).padding(.horizontal, 2)

                Button(action: controller.clearFormatting) {
                    Image(systemName: "textformat")
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Formatierung entfernen")

                Spacer()
                if showsHTMLBadge {
                    Text("HTML")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(.background.opacity(0.45))

            Divider()

            RichTextEditorBridge(
                plainText: $plainText,
                html: $html,
                controller: controller
            )
        }
        .frame(height: height)
        .background(.background.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        )
    }

    private func formatButton(title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

private final class RichTextEditorTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let relevant = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if relevant == .command,
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            selectAll(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct RichTextEditorBridge: NSViewRepresentable {
    private static let editorMagnification: CGFloat = 1.30

    @Binding var plainText: String
    @Binding var html: String
    let controller: RichTextEditorController

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        // Visual editor zoom only. The attributed text itself remains Calibri Light 10.5 pt,
        // so Outlook receives exactly the same mail formatting as before.
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1.0
        scrollView.maxMagnification = 1.8
        scrollView.magnification = Self.editorMagnification

        let textView = RichTextEditorTextView()
        textView.isRichText = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = MailTypography.baseFont
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        controller.textView = textView
        context.coordinator.loadExternalValue(into: textView, force: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        controller.textView = textView
        context.coordinator.loadExternalValue(into: textView, force: false)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditorBridge
        private var isApplyingExternalValue = false

        init(parent: RichTextEditorBridge) {
            self.parent = parent
        }

        func loadExternalValue(into textView: NSTextView, force: Bool) {
            guard force || textView.string != parent.plainText else { return }
            isApplyingExternalValue = true
            defer { isApplyingExternalValue = false }

            textView.textStorage?.setAttributedString(
                MailTypography.attributedString(plainText: parent.plainText, html: parent.html)
            )
            textView.typingAttributes = [.font: MailTypography.baseFont]
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalValue,
                  let textView = notification.object as? NSTextView else { return }
            isApplyingExternalValue = true
            defer { isApplyingExternalValue = false }
            if let storage = textView.textStorage {
                MailTypography.normalizeFonts(in: storage)
            }
            textView.typingAttributes[.font] = MailTypography.font(
                preserving: textView.typingAttributes[.font] as? NSFont
            )
            parent.plainText = textView.string
            parent.html = Self.html(from: textView.attributedString())
        }

        private static func html(from attributed: NSAttributedString) -> String {
            guard attributed.length > 0 else { return "" }
            do {
                let data = try attributed.data(
                    from: NSRange(location: 0, length: attributed.length),
                    documentAttributes: [
                        .documentType: NSAttributedString.DocumentType.html,
                        .characterEncoding: String.Encoding.utf8.rawValue
                    ]
                )
                return String(data: data, encoding: .utf8) ?? ""
            } catch {
                return ""
            }
        }
    }
}
