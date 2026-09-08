import SwiftUI
import AppKit
import Combine
import RichEditorSwiftUI

final class ReplyZenRichEditorAdapter: ObservableObject {
    weak var textView: RichTextView?
    private var storageObserver: NSObjectProtocol?
    private var pendingExternal: (plain: String, html: String)?
    private var pendingExternalWorkItem: DispatchWorkItem?
    private var publishWorkItem: DispatchWorkItem?
    private var isApplyingExternalValue = false
    private var lastPublishedPlain = ""
    private var lastPublishedHTML = ""
    private var publishBindings: ((String, String) -> Void)?

    deinit {
        if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
    }

    func bind(plainText: Binding<String>, html: Binding<String>) {
        publishBindings = { plain, richHTML in
            if plainText.wrappedValue != plain { plainText.wrappedValue = plain }
            if html.wrappedValue != richHTML { html.wrappedValue = richHTML }
        }
    }

    func attach(_ view: RichTextView) {
        if textView === view { return }
        if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
        textView = view
        configure(view)
        if let storage = view.textStorage {
            storageObserver = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification,
                object: storage,
                queue: .main
            ) { [weak self] _ in self?.schedulePublish() }
        }
        applyPendingExternal(force: true)
    }

    private func configure(_ view: RichTextView) {
        view.isEditable = true
        view.isSelectable = true
        view.isRichText = true
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = MailTypography.baseFont
        view.typingAttributes[.font] = MailTypography.baseFont
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
    }

    func updateExternal(plainText: String, html: String) {
        pendingExternal = (plainText, html)
        pendingExternalWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.applyPendingExternal(force: false) }
        pendingExternalWorkItem = item
        DispatchQueue.main.async(execute: item)
    }

    private func applyPendingExternal(force: Bool) {
        guard let pendingExternal, let textView else { return }
        if !force, pendingExternal.plain == lastPublishedPlain, pendingExternal.html == lastPublishedHTML { return }
        let attributed = MailTypography.attributedString(plainText: pendingExternal.plain, html: pendingExternal.html)
        isApplyingExternalValue = true
        textView.setRichText(attributed)
        textView.typingAttributes[.font] = MailTypography.baseFont
        lastPublishedPlain = pendingExternal.plain
        lastPublishedHTML = pendingExternal.html
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in self?.isApplyingExternalValue = false }
    }

    private func schedulePublish() {
        guard !isApplyingExternalValue else { return }
        publishWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.publishCurrentValue() }
        publishWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: item)
    }

    private func publishCurrentValue() {
        guard !isApplyingExternalValue, let textView else { return }
        let normalized = NSMutableAttributedString(attributedString: textView.attributedString())
        MailTypography.normalizeFonts(in: normalized)
        let plain = normalized.string
        let richHTML = MailTypography.htmlDocument(from: normalized)
        lastPublishedPlain = plain
        lastPublishedHTML = richHTML
        publishBindings?(plain, richHTML)
    }

    func toggleBold() { toggleFontTrait(.boldFontMask) }
    func toggleItalic() { toggleFontTrait(.italicFontMask) }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard let textView, let storage = textView.textStorage else { return }
        let manager = NSFontManager.shared
        let selected = textView.selectedRange()
        if selected.length == 0 {
            let font = textView.typingAttributes[.font] as? NSFont ?? MailTypography.baseFont
            let hasTrait = manager.traits(of: font).contains(trait)
            textView.typingAttributes[.font] = hasTrait
                ? manager.convert(font, toNotHaveTrait: trait)
                : manager.convert(font, toHaveTrait: trait)
            objectWillChange.send()
            return
        }
        var allHaveTrait = true
        storage.enumerateAttribute(.font, in: selected) { value, _, stop in
            let font = value as? NSFont ?? MailTypography.baseFont
            if !manager.traits(of: font).contains(trait) { allHaveTrait = false; stop.pointee = true }
        }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: selected) { value, range, _ in
            let font = value as? NSFont ?? MailTypography.baseFont
            let converted = allHaveTrait
                ? manager.convert(font, toNotHaveTrait: trait)
                : manager.convert(font, toHaveTrait: trait)
            storage.addAttribute(.font, value: converted, range: range)
        }
        storage.endEditing()
        textView.didChangeText()
        objectWillChange.send()
    }

    func toggleBullets() { toggleList(style: .bullets) }
    func toggleNumbering() { toggleList(style: .numbered) }

    func clearFormatting() {
        guard let textView, let storage = textView.textStorage else { return }
        let selected = textView.selectedRange()
        if selected.length == 0 {
            textView.typingAttributes = [.font: MailTypography.baseFont]
            return
        }
        storage.beginEditing()
        for key: NSAttributedString.Key in [.font, .foregroundColor, .backgroundColor, .underlineStyle, .strikethroughStyle] {
            storage.removeAttribute(key, range: selected)
        }
        storage.addAttribute(.font, value: MailTypography.baseFont, range: selected)
        storage.endEditing()
        textView.didChangeText()
    }

    private enum ListStyle { case bullets, numbered }
    private func toggleList(style: ListStyle) {
        guard let textView, let storage = textView.textStorage else { return }
        let ns = textView.string as NSString
        let selection = textView.selectedRange()
        if ns.length == 0 {
            let prefix = style == .bullets ? "• " : "1. "
            storage.append(NSAttributedString(string: prefix, attributes: [.font: MailTypography.baseFont]))
            textView.setSelectedRange(NSRange(location: prefix.utf16.count, length: 0))
            textView.didChangeText()
            return
        }
        let safeLocation = min(selection.location, max(0, ns.length - 1))
        let effective = selection.length > 0 ? selection : NSRange(location: safeLocation, length: 0)
        let paragraphRange = ns.paragraphRange(for: effective)
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
        guard !starts.isEmpty else { return }
        func prefixLength(at start: Int, in string: NSString) -> Int {
            let remaining = string.substring(from: start)
            if remaining.hasPrefix("• ") || remaining.hasPrefix("- ") { return 2 }
            let prefix = String(remaining.prefix(12))
            guard let match = prefix.range(of: #"^\d+\.\s"#, options: .regularExpression) else { return 0 }
            return prefix.distance(from: prefix.startIndex, to: match.upperBound)
        }
        let shouldRemove: Bool = {
            switch style {
            case .bullets: return starts.allSatisfy { (textView.string as NSString).substring(from: $0).hasPrefix("• ") }
            case .numbered: return starts.allSatisfy {
                String((textView.string as NSString).substring(from: $0).prefix(12)).range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
            }
            }
        }()
        storage.beginEditing()
        for (index, start) in starts.enumerated().reversed() {
            let current = storage.string as NSString
            let oldLength = prefixLength(at: start, in: current)
            if oldLength > 0 { storage.deleteCharacters(in: NSRange(location: start, length: oldLength)) }
            if !shouldRemove {
                let prefix = style == .bullets ? "• " : "\(index + 1). "
                let attributes = start < storage.length ? storage.attributes(at: start, effectiveRange: nil) : [.font: MailTypography.baseFont]
                storage.insert(NSAttributedString(string: prefix, attributes: attributes), at: start)
            }
        }
        storage.endEditing()
        textView.didChangeText()
    }
}

struct RichTextMailEditor: View {
    @Binding var plainText: String
    @Binding var html: String
    var height: CGFloat? = 176
    var showsHTMLBadge: Bool = true
    @StateObject private var adapter = ReplyZenRichEditorAdapter()

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(adapter: adapter)
            Divider()
            ReplyZenRichEditorSurface(adapter: adapter)
                .frame(minHeight: height == nil ? 180 : nil, maxHeight: .infinity)
                .clipped()
        }
        .frame(height: height)
        .frame(maxHeight: height == nil ? .infinity : nil)
        .layoutPriority(height == nil ? 1 : 0)
        .modifier(WorkspaceCard())
        .onAppear {
            adapter.bind(plainText: $plainText, html: $html)
            adapter.updateExternal(plainText: plainText, html: html)
        }
        .onChange(of: plainText) { newValue in adapter.updateExternal(plainText: newValue, html: html) }
        .onChange(of: html) { newValue in adapter.updateExternal(plainText: plainText, html: newValue) }
    }
}

private struct ReplyZenRichEditorSurface: NSViewRepresentable {
    @ObservedObject var adapter: ReplyZenRichEditorAdapter

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = RichTextView.scrollableTextView()
        scroll.identifier = NSUserInterfaceItemIdentifier("replyzen.mailEditor")
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        if let view = scroll.documentView as? RichTextView { adapter.attach(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let view = scroll.documentView as? RichTextView { adapter.attach(view) }
    }
}
