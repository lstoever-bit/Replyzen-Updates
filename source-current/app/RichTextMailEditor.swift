import SwiftUI
import AppKit
import Combine
import RichEditorSwiftUI

/// Small ReplyZen adapter around the open-source RichEditorSwiftUI editor.
/// The library owns selection/style behavior; ReplyZen only bridges the editor
/// to its existing plain-text/HTML mail pipeline and adds the two list helpers.
final class ReplyZenRichEditorAdapter: ObservableObject {
    let context: RichEditorState
    weak var textView: RichTextView?

    private var storageObserver: NSObjectProtocol?
    private var pendingExternal: (plain: String, html: String)?
    private var pendingExternalWorkItem: DispatchWorkItem?
    private var publishWorkItem: DispatchWorkItem?
    private var isApplyingExternalValue = false
    private var lastPublishedPlain = ""
    private var lastPublishedHTML = ""
    private var publishBindings: ((String, String) -> Void)?

    init(initialText: String) {
        context = RichEditorState(input: initialText)
    }

    deinit {
        if let storageObserver {
            NotificationCenter.default.removeObserver(storageObserver)
        }
    }

    func bind(plainText: Binding<String>, html: Binding<String>) {
        publishBindings = { plain, richHTML in
            if plainText.wrappedValue != plain { plainText.wrappedValue = plain }
            if html.wrappedValue != richHTML { html.wrappedValue = richHTML }
        }
    }

    func attach(_ component: RichTextViewComponent) {
        guard let view = component as? RichTextView else { return }
        if textView === view { return }

        if let storageObserver {
            NotificationCenter.default.removeObserver(storageObserver)
        }
        textView = view
        configure(view)

        if let storage = view.textStorage {
            storageObserver = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification,
                object: storage,
                queue: .main
            ) { [weak self] _ in
                self?.schedulePublish()
            }
        }

        applyPendingExternal(force: true)
    }

    private func configure(_ view: RichTextView) {
        view.isRichText = true
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = MailTypography.baseFont
        view.typingAttributes[.font] = MailTypography.baseFont
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true

        // Fixed visual magnification keeps 10.5 pt mail text comfortable to edit,
        // without adding another control or changing what Outlook receives.
        DispatchQueue.main.async { [weak view] in
            guard let scrollView = view?.enclosingScrollView else { return }
            scrollView.identifier = NSUserInterfaceItemIdentifier("replyzen.mailEditor")
            scrollView.hasVerticalScroller = true
            scrollView.drawsBackground = false
            scrollView.allowsMagnification = true
            scrollView.minMagnification = 1.0
            scrollView.maxMagnification = 1.8
            scrollView.magnification = 1.30
        }
    }

    func updateExternal(plainText: String, html: String) {
        pendingExternal = (plainText, html)
        pendingExternalWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.applyPendingExternal(force: false)
        }
        pendingExternalWorkItem = item
        // Coalesce SwiftUI updates to plainText + html into one editor update.
        DispatchQueue.main.async(execute: item)
    }

    private func applyPendingExternal(force: Bool) {
        guard let pendingExternal, let textView else { return }
        if !force,
           pendingExternal.plain == lastPublishedPlain,
           pendingExternal.html == lastPublishedHTML {
            return
        }

        let attributed = MailTypography.attributedString(
            plainText: pendingExternal.plain,
            html: pendingExternal.html
        )
        isApplyingExternalValue = true
        context.setAttributedString(to: attributed)
        textView.setRichText(attributed)
        textView.typingAttributes[.font] = MailTypography.baseFont
        lastPublishedPlain = pendingExternal.plain
        lastPublishedHTML = pendingExternal.html

        // The package and NSTextStorage can emit one more attribute notification
        // after setRichText. Keep that out of the parent bindings.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.isApplyingExternalValue = false
        }
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
        // Normalize a copy. The WYSIWYG editor keeps its own live attributes,
        // while Outlook still receives ReplyZen's Calibri Light 10.5 pt contract.
        MailTypography.normalizeFonts(in: normalized)
        let plain = normalized.string
        let richHTML = MailTypography.htmlDocument(from: normalized)
        lastPublishedPlain = plain
        lastPublishedHTML = richHTML
        publishBindings?(plain, richHTML)
    }

    func toggleBullets() {
        toggleList(style: .bullets)
    }

    func toggleNumbering() {
        toggleList(style: .numbered)
    }

    func clearFormatting() {
        guard let textView, let storage = textView.textStorage else { return }
        let selected = textView.selectedRange()
        if selected.length == 0 {
            textView.typingAttributes = [.font: MailTypography.baseFont]
            return
        }

        storage.beginEditing()
        for key: NSAttributedString.Key in [
            .font, .foregroundColor, .backgroundColor,
            .underlineStyle, .strikethroughStyle
        ] {
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
        let effective = selection.length > 0
            ? selection
            : NSRange(location: safeLocation, length: 0)
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
            case .bullets:
                return starts.allSatisfy { (textView.string as NSString).substring(from: $0).hasPrefix("• ") }
            case .numbered:
                return starts.allSatisfy {
                    let prefix = String((textView.string as NSString).substring(from: $0).prefix(12))
                    return prefix.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
                }
            }
        }()

        storage.beginEditing()
        for (index, start) in starts.enumerated().reversed() {
            let current = storage.string as NSString
            let oldLength = prefixLength(at: start, in: current)
            if oldLength > 0 {
                storage.deleteCharacters(in: NSRange(location: start, length: oldLength))
            }
            if !shouldRemove {
                let prefix = style == .bullets ? "• " : "\(index + 1). "
                let attributes: [NSAttributedString.Key: Any]
                if start < storage.length {
                    attributes = storage.attributes(at: start, effectiveRange: nil)
                } else {
                    attributes = [.font: MailTypography.baseFont]
                }
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
    @StateObject private var adapter: ReplyZenRichEditorAdapter

    init(
        plainText: Binding<String>,
        html: Binding<String>,
        height: CGFloat? = 176,
        showsHTMLBadge: Bool = true
    ) {
        _plainText = plainText
        _html = html
        self.height = height
        self.showsHTMLBadge = showsHTMLBadge
        _adapter = StateObject(
            wrappedValue: ReplyZenRichEditorAdapter(initialText: plainText.wrappedValue)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(context: adapter.context, adapter: adapter)
            Divider()
            ReplyZenRichEditorSurface(context: adapter.context, adapter: adapter)
                .frame(minHeight: height == nil ? 80 : nil, maxHeight: .infinity)
        }
        .frame(height: height)
        .frame(maxHeight: height == nil ? .infinity : nil)
        .modifier(WorkspaceCard())
        .onAppear {
            adapter.bind(plainText: $plainText, html: $html)
            adapter.updateExternal(plainText: plainText, html: html)
        }
        .onChange(of: plainText) { newValue in
            adapter.updateExternal(plainText: newValue, html: html)
        }
        .onChange(of: html) { newValue in
            adapter.updateExternal(plainText: plainText, html: newValue)
        }
    }
}

private struct ReplyZenRichEditorSurface: View {
    @ObservedObject var context: RichEditorState
    let adapter: ReplyZenRichEditorAdapter

    var body: some View {
        RichTextEditor(
            context: _context,
            viewConfiguration: { component in
                adapter.attach(component)
            }
        )
    }
}
