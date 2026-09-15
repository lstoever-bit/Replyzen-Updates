import SwiftUI
import AppKit
import Combine
import RichEditorSwiftUI

extension Notification.Name {
    static let replyZenCommitRichEditors = Notification.Name("ReplyZen.CommitRichEditors")
}

final class ReplyZenRichEditorAdapter: ObservableObject {
    weak var textView: RichTextView?
    private weak var scrollView: NSScrollView?
    private var keyMonitor: Any?
    private var wrapObservers: [NSObjectProtocol] = []
    private var wrapWorkItem: DispatchWorkItem?
    private var lastWrapWidth: CGFloat = 0
    private var isNormalizingParagraphStyles = false
    @Published private(set) var zoomPercent: Int = {
        let saved = UserDefaults.standard.integer(forKey: "ReplyZen.EditorZoomPercent")
        return [100, 115, 130, 150, 180].contains(saved) ? saved : 130
    }()
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
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        wrapWorkItem?.cancel()
        for observer in wrapObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func bind(plainText: Binding<String>, html: Binding<String>) {
        publishBindings = { plain, richHTML in
            if plainText.wrappedValue != plain { plainText.wrappedValue = plain }
            if html.wrappedValue != richHTML { html.wrappedValue = richHTML }
        }
    }

    func attachZoom(to scrollView: NSScrollView) {
        if self.scrollView === scrollView { return }
        self.scrollView = scrollView
        installWrapObservers(for: scrollView)

        // NSScrollView magnification creates a zoomed document viewport. That is
        // useful for canvases, but wrong for a mail composer because the logical
        // text width can extend beyond the visible Rich Text Box. Keep TextKit at
        // 1:1 and implement ReplyZen's display-only zoom through font rendering.
        scrollView.allowsMagnification = false
        scrollView.magnification = 1.0
        applyDisplayZoom()
        scheduleWrapUpdate()
    }

    func setZoom(percent: Int) {
        let clamped = min(180, max(100, percent))
        guard clamped != zoomPercent else { return }
        zoomPercent = clamped
        UserDefaults.standard.set(clamped, forKey: "ReplyZen.EditorZoomPercent")
        applyDisplayZoom()
        updateWrapWidth()
    }

    private func displayFont(preserving source: NSFont?) -> NSFont {
        let normalized = MailTypography.font(preserving: source)
        let size = MailTypography.pointSize * CGFloat(zoomPercent) / 100.0
        return NSFont(descriptor: normalized.fontDescriptor, size: size) ?? normalized
    }

    private func applyDisplayZoom() {
        guard let textView else { return }
        let wasApplyingExternalValue = isApplyingExternalValue
        isApplyingExternalValue = true

        if let storage = textView.textStorage, storage.length > 0 {
            let fullRange = NSRange(location: 0, length: storage.length)
            var changes: [(NSRange, NSFont)] = []
            storage.enumerateAttribute(.font, in: fullRange) { value, range, _ in
                let old = value as? NSFont
                let desired = displayFont(preserving: old)
                if old?.fontName != desired.fontName || abs((old?.pointSize ?? 0) - desired.pointSize) > 0.01 {
                    changes.append((range, desired))
                }
            }
            if !changes.isEmpty {
                storage.beginEditing()
                for (range, font) in changes { storage.addAttribute(.font, value: font, range: range) }
                storage.endEditing()
            }
        }

        textView.font = displayFont(preserving: textView.font)
        textView.typingAttributes[.font] = displayFont(preserving: textView.typingAttributes[.font] as? NSFont)
        isApplyingExternalValue = wasApplyingExternalValue
        textView.needsDisplay = true
    }

    func attach(_ view: RichTextView) {
        if textView === view { return }
        if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
        textView = view
        configure(view)
        installShortcutMonitor(for: view)
        updateWrapWidth()
        if let storage = view.textStorage {
            storageObserver = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification,
                object: storage,
                queue: .main
            ) { [weak self] _ in
                self?.normalizeParagraphWrapping()
                self?.scheduleWrapUpdate()
                self?.schedulePublish()
            }
        }
        applyPendingExternal(force: true)
    }

    private func configure(_ view: RichTextView) {
        view.isEditable = true
        view.isSelectable = true
        view.isRichText = true
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = displayFont(preserving: nil)
        view.typingAttributes[.font] = displayFont(preserving: nil)
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.textContainer?.widthTracksTextView = true
        normalizeParagraphWrapping()
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
        applyDisplayZoom()
        textView.typingAttributes[.font] = displayFont(preserving: textView.typingAttributes[.font] as? NSFont)
        lastPublishedPlain = pendingExternal.plain
        lastPublishedHTML = pendingExternal.html
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in self?.isApplyingExternalValue = false }
    }

    private func schedulePublish() {
        guard !isApplyingExternalValue else { return }
        publishWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.publishCurrentValue() }
        publishWorkItem = item
        // Queue on the current run loop with no artificial debounce. This keeps the
        // SwiftUI binding current before a following mouse click can generate mail.
        DispatchQueue.main.async(execute: item)
    }

    func flushPendingEdits() {
        publishWorkItem?.cancel()
        publishWorkItem = nil
        publishCurrentValue()
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

    func refreshWrapping() {
        scheduleWrapUpdate()
    }

    private func installWrapObservers(for scrollView: NSScrollView) {
        for observer in wrapObservers { NotificationCenter.default.removeObserver(observer) }
        wrapObservers.removeAll()

        scrollView.postsFrameChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        for view in [scrollView as NSView, scrollView.contentView as NSView] {
            wrapObservers.append(center.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: view,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleWrapUpdate()
            })
        }
    }

    private func scheduleWrapUpdate() {
        wrapWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.updateWrapWidth() }
        wrapWorkItem = item
        DispatchQueue.main.async(execute: item)
    }

    private func normalizeParagraphWrapping() {
        guard !isNormalizingParagraphStyles, let textView else { return }
        isNormalizingParagraphStyles = true
        defer { isNormalizingParagraphStyles = false }

        if let storage = textView.textStorage, storage.length > 0 {
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
                guard let current = value as? NSParagraphStyle,
                      current.lineBreakMode != .byWordWrapping,
                      let style = current.mutableCopy() as? NSMutableParagraphStyle else { return }
                style.lineBreakMode = .byWordWrapping
                storage.addAttribute(.paragraphStyle, value: style, range: range)
            }
            storage.endEditing()
        }

        let typingStyle = ((textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
            ?? NSMutableParagraphStyle()
        typingStyle.lineBreakMode = .byWordWrapping
        textView.typingAttributes[.paragraphStyle] = typingStyle
    }

    private func updateWrapWidth() {
        guard let scrollView, let textView else { return }
        scrollView.layoutSubtreeIfNeeded()

        // With scroll magnification disabled, documentVisibleRect is the actual
        // editable width visible through the clip view. TextKit gets exactly that
        // width, so the document cannot create a horizontal overflow range.
        let visibleWidth = scrollView.documentVisibleRect.width
        let fallbackWidth = scrollView.contentSize.width
        let width = max(CGFloat(120), visibleWidth > 1 ? visibleWidth : fallbackWidth)

        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        if abs(textView.frame.width - width) > 0.5 || abs(lastWrapWidth - width) > 0.5 {
            var frame = textView.frame
            frame.size.width = width
            frame.size.height = max(frame.size.height, scrollView.documentVisibleRect.height)
            textView.frame = frame
            lastWrapWidth = width
        }

        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            container.lineBreakMode = .byWordWrapping
            textView.layoutManager?.ensureLayout(for: container)
        }
        normalizeParagraphWrapping()

        var origin = scrollView.contentView.bounds.origin
        if origin.x != 0 {
            origin.x = 0
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func installShortcutMonitor(for view: RichTextView) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
            guard let self, let view, self.textView === view,
                  view.window?.firstResponder === view else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) || flags.contains(.control),
                  let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
            switch key {
            case "a":
                view.selectAll(nil)
                return nil
            case "c":
                view.copy(nil)
                return nil
            case "v":
                view.paste(nil)
                return nil
            case "x":
                view.cut(nil)
                return nil
            case "z":
                if flags.contains(.shift) { view.undoManager?.redo() } else { view.undoManager?.undo() }
                return nil
            default:
                return event
            }
        }
    }

    func toggleBold() { toggleFontTrait(.boldFontMask) }
    func toggleItalic() { toggleFontTrait(.italicFontMask) }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard let textView, let storage = textView.textStorage else { return }
        let manager = NSFontManager.shared
        let selected = textView.selectedRange()
        if selected.length == 0 {
            let font = textView.typingAttributes[.font] as? NSFont ?? displayFont(preserving: nil)
            let hasTrait = manager.traits(of: font).contains(trait)
            textView.typingAttributes[.font] = hasTrait
                ? manager.convert(font, toNotHaveTrait: trait)
                : manager.convert(font, toHaveTrait: trait)
            objectWillChange.send()
            return
        }
        var allHaveTrait = true
        storage.enumerateAttribute(.font, in: selected) { value, _, stop in
            let font = value as? NSFont ?? displayFont(preserving: nil)
            if !manager.traits(of: font).contains(trait) { allHaveTrait = false; stop.pointee = true }
        }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: selected) { value, range, _ in
            let font = value as? NSFont ?? displayFont(preserving: nil)
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
            textView.typingAttributes = [.font: displayFont(preserving: nil)]
            return
        }
        storage.beginEditing()
        for key: NSAttributedString.Key in [.font, .foregroundColor, .backgroundColor, .underlineStyle, .strikethroughStyle] {
            storage.removeAttribute(key, range: selected)
        }
        storage.addAttribute(.font, value: displayFont(preserving: nil), range: selected)
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
            storage.append(NSAttributedString(string: prefix, attributes: [.font: displayFont(preserving: nil)]))
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
                let attributes = start < storage.length ? storage.attributes(at: start, effectiveRange: nil) : [.font: displayFont(preserving: nil)]
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
        .onReceive(NotificationCenter.default.publisher(for: .replyZenCommitRichEditors)) { _ in
            adapter.flushPendingEdits()
        }
    }
}

private struct ReplyZenRichEditorSurface: NSViewRepresentable {
    @ObservedObject var adapter: ReplyZenRichEditorAdapter

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = RichTextView.scrollableTextView()
        scroll.identifier = NSUserInterfaceItemIdentifier("replyzen.mailEditor")
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.contentView.postsFrameChangedNotifications = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        adapter.attachZoom(to: scroll)
        if let view = scroll.documentView as? RichTextView { adapter.attach(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        adapter.attachZoom(to: scroll)
        if let view = scroll.documentView as? RichTextView { adapter.attach(view) }
        adapter.refreshWrapping()
    }
}
