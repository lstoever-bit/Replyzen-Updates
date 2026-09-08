#!/usr/bin/env python3
"""Migrate ReplyZen 1.54 to 1.55: remove Payment and stabilize first window render."""
from pathlib import Path
import json
import plistlib
import sys

root = Path(sys.argv[1])
app = root / "app"
info_path = app / "Info.plist"
info = plistlib.loads(info_path.read_bytes())

if info["CFBundleShortVersionString"] == "1.55.0":
    print("ReplyZen 1.55 migration already applied")
    raise SystemExit(0)
if info["CFBundleShortVersionString"] != "1.54.0":
    raise SystemExit("Unexpected source version; refusing to modify newer work")


def once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise RuntimeError("Expected one source marker: " + old[:140])
    return text.replace(old, new, 1)


def remove_swift_block(text: str, marker: str) -> str:
    """Remove a function/computed property by balancing braces while ignoring strings/comments."""
    start = text.find(marker)
    if start < 0:
        raise RuntimeError("Missing Swift block: " + marker)
    brace = text.find("{", start)
    if brace < 0:
        raise RuntimeError("Missing opening brace: " + marker)
    i = brace
    depth = 0
    in_string = False
    in_multiline = False
    in_line_comment = False
    block_comment_depth = 0
    escaped = False
    while i < len(text):
        if in_line_comment:
            if text[i] == "\n": in_line_comment = False
            i += 1
            continue
        if block_comment_depth:
            if text.startswith("/*", i): block_comment_depth += 1; i += 2; continue
            if text.startswith("*/", i): block_comment_depth -= 1; i += 2; continue
            i += 1
            continue
        if in_multiline:
            if text.startswith('"""', i): in_multiline = False; i += 3; continue
            i += 1
            continue
        if in_string:
            c = text[i]
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == '"':
                in_string = False
            i += 1
            continue
        if text.startswith("//", i): in_line_comment = True; i += 2; continue
        if text.startswith("/*", i): block_comment_depth = 1; i += 2; continue
        if text.startswith('"""', i): in_multiline = True; i += 3; continue
        c = text[i]
        if c == '"': in_string = True; i += 1; continue
        if c == "{": depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                while end < len(text) and text[end] in " \t": end += 1
                if end < len(text) and text[end] == "\n": end += 1
                if end < len(text) and text[end] == "\n": end += 1
                return text[:start] + text[end:]
        i += 1
    raise RuntimeError("Unbalanced Swift block: " + marker)


# ---- Remove Payment from application state ----
path = app / "AppState.swift"
s = path.read_text(encoding="utf-8")
s = once(s, "        case calendar\n        case payment\n", "        case calendar\n")
s = once(s, '            case .calendar: return L10n.tr("Termin")\n            case .payment: return L10n.tr("Überweisung")\n', '            case .calendar: return L10n.tr("Termin")\n')
s = once(s, "        case calendarPreview\n        case paymentPreview\n", "        case calendarPreview\n")
for line in [
    '    @Published var paymentRecipient: String = ""\n',
    '    @Published var paymentIBAN: String = ""\n',
    '    @Published var paymentBIC: String = ""\n',
    '    @Published var paymentAmount: String = ""\n',
    '    @Published var paymentCurrency: String = "EUR"\n',
    '    @Published var paymentPurpose: String = ""\n',
    '    @Published var paymentSourceStatus: String = ""\n',
    '    @Published var paymentWarning: String = ""\n',
    '    var extractPaymentAction: (() -> Void)?\n',
    '    var copyPaymentAction: (() -> Void)?\n',
]:
    s = s.replace(line, "")
path.write_text(s, encoding="utf-8")


# ---- Remove Payment from main controller ----
path = app / "AppDelegate.swift"
s = path.read_text(encoding="utf-8")
for line in [
    '    private let attachmentExtractor = AttachmentTextExtractor()\n',
    '        state.extractPaymentAction = { [weak self] in self?.generatePaymentSuggestion() }\n',
    '        state.copyPaymentAction = { [weak self] in self?.copyPaymentDetails() }\n',
    '        toolbarButton.paymentAction = { [weak self] in self?.createPaymentFromOverlay() }\n',
]:
    s = s.replace(line, "")
for marker in [
    "    private func createPaymentFromOverlay() {",
    "    private func generatePaymentSuggestion() {",
    "    private func choosePaymentPDFFallback(suggestedName: String?) -> URL? {",
    "    private func copyPaymentDetails() {",
]:
    if marker in s:
        s = remove_swift_block(s, marker)
s = s.replace("        case .calendar, .payment:\n", "        case .calendar:\n")
s = s.replace("        case .payment:\n            generatePaymentSuggestion()\n", "")
path.write_text(s, encoding="utf-8")


# ---- Remove Payment button and callback from Outlook action overlay ----
path = app / "OutlookToolbarButtonController.swift"
s = path.read_text(encoding="utf-8")
s = s.replace("    private let paymentButton: DelayedTooltipButton\n", "")
s = s.replace("    var paymentAction: (() -> Void)?\n", "")
s = s.replace("NSSize(width: 322, height: 34)", "NSSize(width: 282, height: 34)")
s = s.replace("        paymentButton = makeButton(symbol: \"banknote\", x: 278, tooltip: L10n.source(\"Payment\"))\n", "")
s = s.replace(", paymentButton", "")
s = s.replace("        paymentButton.target = self\n", "")
s = s.replace("        paymentButton.action = #selector(paymentClicked)\n", "")
s = s.replace("    @objc private func paymentClicked() { paymentAction?() }\n", "")
path.write_text(s, encoding="utf-8")


# ---- Simplify workspace to Mail + Calendar only ----
path = app / "MailWorkspaceView.swift"
s = path.read_text(encoding="utf-8")
s = s.replace("        case .calendar, .payment: return state.mailStatus == .available\n", "        case .calendar: return state.mailStatus == .available\n")
s = s.replace("        case .calendar, .payment: break\n", "        case .calendar: break\n")
s = remove_swift_block(s, "    private var extractionCard: some View {")
insert = s.index("    private var primaryTitle: String {")
calendar_card = '''    private var extractionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.tr("Termin aus Mail"), systemImage: "calendar.badge.plus")
                .font(.title3.weight(.semibold))
            Text(L10n.tr("Titel, Kurzbeschreibung und erkennbaren Zeitpunkt aus der Mail übernehmen. Den Zielkalender wählst du anschließend aus."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(WorkspaceCard())
    }

'''
s = s[:insert] + calendar_card + s[insert:]
s = s.replace('        case .payment: return L10n.tr("Überweisung extrahieren")\n', "")
path.write_text(s, encoding="utf-8")


# ---- Remove Payment preview and wording from the main SwiftUI surface ----
path = app / "OverlayView.swift"
s = path.read_text(encoding="utf-8")
s = s.replace(" || state.stage == .paymentPreview", "")
start = s.find("        case .paymentPreview:")
if start >= 0:
    end = s.find("        case .inserting:", start)
    if end < 0: raise RuntimeError("Could not remove payment preview switch case")
    s = s[:start] + s[end:]
for marker in ["    private var paymentPreviewView: some View {", "    private var paymentFooter: some View {"]:
    if marker in s: s = remove_swift_block(s, marker)
s = s.replace('Text(L10n.tr("Mail, Termin oder Überweisung, direkt aus Outlook."))', 'Text(L10n.tr("Mail und Termin, direkt aus Outlook."))')
s = s.replace('        case .payment: return L10n.tr("Ich lese den PDF-Anhang und extrahiere die Überweisungsdaten …")\n', "")
s = s.replace("        case .calendar, .payment:\n", "        case .calendar:\n")
s = s.replace('        case .payment: return L10n.tr("Überweisung prüfen")\n', "")
path.write_text(s, encoding="utf-8")


# ---- Window: recreate the SwiftUI hosting tree whenever a hidden workspace opens ----
# The previous redraw passes were not sufficient with the third-party representable.
path = app / "FloatingPanelController.swift"
s = path.read_text(encoding="utf-8")
s = once(s,
'''        let host = NSHostingController(rootView: OverlayView(state: state))
        panel.contentViewController = host
''',
'''        panel.contentViewController = NSHostingController(rootView: OverlayView(state: state))
''')
needle = '''    func show(activate: Bool = true) {
        cancelScheduledResize()
        wantsVisibleInOutlookContext = true
        // Every explicit opening starts centered, independent of any old frame.
        resizeForCurrentState(animated: false, centered: true)
'''
replacement = '''    private func installFreshHostingRoot() {
        // A fresh hosting tree avoids stale AppKit representable geometry from a
        // previously hidden editor. AppState keeps the user's draft/content intact.
        panel.contentViewController = NSHostingController(rootView: OverlayView(state: state))
        panel.contentViewController?.view.needsLayout = true
        panel.contentViewController?.view.layoutSubtreeIfNeeded()
    }

    func show(activate: Bool = true) {
        cancelScheduledResize()
        wantsVisibleInOutlookContext = true
        if !panel.isVisible {
            installFreshHostingRoot()
        }
        // Every explicit opening starts centered, independent of any old frame.
        resizeForCurrentState(animated: false, centered: true)
'''
s = once(s, needle, replacement)
s = s.replace("            case .calendar, .payment: return NSSize(width: 840, height: 640)\n", "            case .calendar: return NSSize(width: 840, height: 640)\n")
s = s.replace("        case .paymentPreview: return NSSize(width: 840, height: 690)\n", "")
path.write_text(s, encoding="utf-8")


# ---- Replace the flaky package representable with a stable NSViewRepresentable ----
# We still use RichEditorSwiftUI's MIT-licensed RichTextView, but own one native
# NSScrollView per SwiftUI identity instead of letting a value-type representable
# recreate its AppKit scroll view during first layout.
editor = r'''import SwiftUI
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
'''
(app / "RichTextMailEditor.swift").write_text(editor, encoding="utf-8")

editor_toolbar = r'''import SwiftUI

struct EditorToolbar: View {
    @ObservedObject private var appLocalization = AppLocalization.shared
    @ObservedObject var adapter: ReplyZenRichEditorAdapter

    var body: some View {
        HStack(spacing: 4) {
            tool("bold", title: L10n.tr("Fett"), action: adapter.toggleBold)
            tool("italic", title: L10n.tr("Kursiv"), action: adapter.toggleItalic)
            separator
            tool("list.bullet", title: L10n.tr("Aufzählung"), action: adapter.toggleBullets)
            tool("list.number", title: L10n.tr("Nummerierte Liste"), action: adapter.toggleNumbering)
            separator
            tool("textformat", title: L10n.tr("Formatierung entfernen"), action: adapter.clearFormatting)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var separator: some View { Divider().frame(height: 16).padding(.horizontal, 4) }
    private func tool(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.borderless).help(title).accessibilityLabel(title)
    }
}
'''
(app / "EditorToolbar.swift").write_text(editor_toolbar, encoding="utf-8")

# Payment-only local attachment extraction is no longer part of the product.
attachment = app / "AttachmentTextExtractor.swift"
if attachment.exists(): attachment.unlink()

# Add localized copy for the payment-free ready screen.
catalog_path = app / "Resources" / "Localization.json"
catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
catalog["Mail und Termin, direkt aus Outlook."] = {
    "de": "Mail und Termin, direkt aus Outlook.",
    "en-US": "Mail and calendar, directly from Outlook.",
    "es": "Correo y calendario, directamente desde Outlook."
}
catalog_path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

# ---- Tests: remove Payment assumptions and add strong source contracts ----
client_checks = r'''// Appended to OpenAIClient.swift by run-tests.sh to exercise private decoders.
extension OpenAIClient {
    static func runDecoderChecks() throws {
        let reply = try decodeReplyDraft("{\"body\":\"Hello\",\"html\":\"<p>Hello</p>\"}")
        precondition(reply.body == "Hello" && reply.html == "<p>Hello</p>")
        let fenced = try decodeReplyDraft("```json\n{\"body\":\"Hallo\",\"html\":null}\n```")
        precondition(fenced.body == "Hallo" && fenced.html == nil)
        let newMail = try decodeNewMailDraft("{\"subject\":\"Test\",\"body\":\"Hello\",\"html\":null}")
        precondition(newMail.subject == "Test" && newMail.body == "Hello")
        let event = try decodeCalendarSuggestion("{\"title\":\"Test\",\"description\":\"Description\",\"start\":null,\"end\":null,\"confidence\":\"missing\"}")
        precondition(event.start == nil && event.end == nil && event.title == "Test")
        let invalid: [() throws -> Void] = [
            { _ = try decodeReplyDraft("not JSON") },
            { _ = try decodeReplyDraft("{\"body\":\"  \"}") },
            { _ = try decodeNewMailDraft("{\"subject\":\"Test\",\"body\":\"\"}") },
            { _ = try decodeNewMailDraft("{}") },
            { _ = try decodeCalendarSuggestion("{}") }
        ]
        for operation in invalid {
            do { try operation(); fatalError("Expected API error") }
            catch { precondition(error is APIError) }
        }
        let output = Data("{\"output\":[{\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"},{\"type\":\"output_text\",\"text\":\"world\"}]}]}".utf8)
        precondition(try extractOutputText(from: output) == "Hello\nworld")
        let error = Data("{\"error\":{\"message\":\"Test error\"}}".utf8)
        precondition(extractErrorMessage(from: error) == "Test error")
        precondition(extractErrorMessage(from: Data("{}".utf8)) == nil)
        print("PASS: mail/calendar client decoder and error cases")
    }
}

@main
struct ClientCheckRunner {
    static func main() throws { try OpenAIClient.runDecoderChecks() }
}
'''
(root.parent / "tests" / "ClientDecoderChecks.swift").write_text(client_checks, encoding="utf-8")

response_path = root.parent / "tests" / "ResponseJSONTests.swift"
t = response_path.read_text(encoding="utf-8")
t = t.replace('            "{\\"iban\\":null,\\"amount\\":\\"123.45\\",\\"currency\\":\\"EUR\\"}"\n', "")
t = t.replace("10 JSON normalization cases and 4 output schemas", "10 JSON normalization cases and 3 output schemas")
response_path.write_text(t, encoding="utf-8")

stubs_path = root.parent / "tests" / "WindowPositionTestDoubles.swift"
t = stubs_path.read_text(encoding="utf-8")
t = t.replace("calendarPreview, paymentPreview, preview", "calendarPreview, preview")
t = t.replace("forward, calendar, payment", "forward, calendar")
stubs_path.write_text(t, encoding="utf-8")

behavior_path = root.parent / "tests" / "WindowPositionBehaviorTests.swift"
t = behavior_path.read_text(encoding="utf-8")
t = t.replace("count: 7", "count: 6")
t = t.replace("        toolbar.paymentAction = { clicks[6] += 1 }\n", "")
t = t.replace("buttons.count == 7", "buttons.count == 6")
t = t.replace("all seven actions", "all six actions")
behavior_path.write_text(t, encoding="utf-8")

contracts = r'''#!/usr/bin/env python3
from pathlib import Path
import plistlib
import sys
import unittest
ROOT = Path(sys.argv[1]); sys.argv = [sys.argv[0]]; APP = ROOT / "app"

class SourceContracts(unittest.TestCase):
    def read(self, name): return (APP / name).read_text(encoding="utf-8")
    def test_identity_and_version(self):
        info = plistlib.loads((APP / "Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "com.lstoever.replyzen")
        self.assertEqual(info["CFBundleDisplayName"], "ReplyZen")
        self.assertEqual(info["CFBundleShortVersionString"], "1.55.0")
        self.assertEqual(info["CFBundleVersion"], "56")
    def test_payment_is_removed_from_active_code(self):
        self.assertFalse((APP / "AttachmentTextExtractor.swift").exists())
        swift = "\n".join(p.read_text(encoding="utf-8") for p in APP.glob("*.swift"))
        lowered = swift.lower()
        for token in ["payment", "überweisung", "banknote", "paymentpreview", "paymentrecipient"]:
            self.assertNotIn(token, lowered)
    def test_outlook_overlay_has_six_actions(self):
        toolbar = self.read("OutlookToolbarButtonController.swift")
        self.assertIn("NSSize(width: 282, height: 34)", toolbar)
        for action in ["new", "reply", "replyAll", "forward", "cancel", "calendar"]:
            self.assertIn(action + "Action?()", toolbar)
        self.assertNotIn("paymentAction", toolbar)
    def test_fresh_hosting_tree_on_hidden_open(self):
        panel = self.read("FloatingPanelController.swift")
        self.assertIn("private func installFreshHostingRoot()", panel)
        self.assertIn("if !panel.isVisible", panel)
        self.assertIn("NSHostingController(rootView: OverlayView(state: state))", panel)
        self.assertIn("resizeForCurrentState(animated: false, centered: true)", panel)
        self.assertNotIn("defaults.set(", panel)
    def test_stable_native_wysiwyg_wrapper(self):
        editor = self.read("RichTextMailEditor.swift")
        toolbar = self.read("EditorToolbar.swift")
        package = (ROOT / "Package.swift").read_text(encoding="utf-8")
        self.assertIn("rich-editor-swiftui.git", package)
        self.assertIn('exact: "1.1.1"', package)
        self.assertIn("import RichEditorSwiftUI", editor)
        self.assertIn("NSViewRepresentable", editor)
        self.assertIn("RichTextView.scrollableTextView()", editor)
        self.assertNotIn("RichTextEditor(", editor)
        self.assertNotIn("RichEditorState", editor)
        self.assertIn("adapter.toggleBold", toolbar)
        self.assertIn("adapter.toggleItalic", toolbar)
        self.assertIn("MailTypography.normalizeFonts", editor)
    def test_existing_mail_calendar_paths(self):
        delegate = self.read("AppDelegate.swift")
        for flow in ["openNewMailWorkspace", "openReplyWorkspace", "openForwardWorkspace", "quickDecline", "createCalendarFromOverlay"]:
            self.assertIn(flow + "(", delegate)
        state = self.read("AppState.swift")
        for mode in ["case reply", "case newMail", "case forward", "case calendar"]:
            self.assertIn(mode, state)
    def test_json_pipeline(self):
        client = self.read("OpenAIClient.swift")
        self.assertEqual(client.count("ResponseJSON.cleanedText(text)"), 3)
        self.assertNotIn("PaymentSuggestion", client)
        self.assertNotIn("uploadFile(", client)
        self.assertNotIn("fileIOQueue", client)
        self.assertIn('"store": false', client)
    def test_typography_contract(self):
        typography = self.read("MailTypography.swift")
        self.assertIn("static let pointSize: CGFloat = 10.5", typography)
        self.assertIn('static let family = "Calibri Light"', typography)
        self.assertIn("MailTypography.baseFont", self.read("RichTextMailEditor.swift"))
    def test_window_position_contract(self):
        panel = self.read("FloatingPanelController.swift")
        self.assertIn("panel.isMovable = true", panel)
        self.assertIn("panel.isRestorable = false", panel)
        self.assertIn('panel.setFrameAutosaveName("")', panel)
        self.assertIn('defaults.removeObject(forKey: "Replyzen.FloatingPanel.Frame.v1")', panel)
        toolbar = self.read("OutlookToolbarButtonController.swift")
        self.assertIn("defaults.set(Double(toolbarOffset.x)", toolbar)
        self.assertIn("defaults.set(Double(toolbarOffset.y)", toolbar)

if __name__ == "__main__": unittest.main(verbosity=2)
'''
(root.parent / "tests" / "test_source_contracts.py").write_text(contracts, encoding="utf-8")

# Remove the entire Payment/OpenAI file path: struct + uploads + decoder are contiguous.
path = app / "OpenAIClient.swift"
s = path.read_text(encoding="utf-8")
s = s.replace('    private let fileIOQueue = DispatchQueue(label: "com.lstoever.replyzen.file-io", qos: .userInitiated)\n\n', "")
start = s.find("    struct PaymentSuggestion: Decodable {")
end = s.find("    private func languageInstruction(", start)
if start < 0 or end < 0: raise RuntimeError("Could not locate complete OpenAI Payment section")
s = s[:start] + s[end:]
path.write_text(s, encoding="utf-8")

# Version/build and release notes.
info["CFBundleShortVersionString"] = "1.55.0"
info["CFBundleVersion"] = "56"
info_path.write_bytes(plistlib.dumps(info, sort_keys=False))

notes = {
    "de": "ReplyZen 1.55: Die Payment-/Überweisungsfunktion wurde vollständig aus Oberfläche und aktiver App-Logik entfernt. Das große ReplyZen-Fenster verwendet für den WYSIWYG-Editor jetzt einen stabilen nativen AppKit-Wrapper und baut beim Öffnen aus verborgenem Zustand einen frischen SwiftUI-Hosting-Baum auf. Dadurch soll die Oberfläche direkt beim ersten Öffnen vollständig erscheinen, ohne vorherigen Fensterwechsel. Mail, Reply/Reply All, Forward, Cancel und Kalender bleiben erhalten.",
    "en-US": "ReplyZen 1.55: The Payment/bank-transfer feature has been completely removed from the interface and active app logic. The main ReplyZen window now uses a stable native AppKit wrapper for the WYSIWYG editor and creates a fresh SwiftUI hosting tree whenever it opens from a hidden state. This is designed to render the complete interface on the first opening without requiring a window switch. Mail, Reply/Reply All, Forward, Cancel and Calendar remain available.",
    "es": "ReplyZen 1.55: La función de pagos/transferencias bancarias se ha eliminado por completo de la interfaz y de la lógica activa de la aplicación. La ventana principal de ReplyZen utiliza ahora un contenedor AppKit nativo y estable para el editor WYSIWYG y crea un nuevo árbol de SwiftUI cada vez que se abre desde un estado oculto. Así la interfaz debe mostrarse completa desde la primera apertura sin cambiar antes de ventana. Mail, Reply/Reply All, Forward, Cancel y Calendar siguen disponibles."
}
(root / "Release-notes.txt").write_text(notes["de"] + "\n", encoding="utf-8")
(root / "Release-notes.localized.json").write_text(json.dumps(notes, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

verify_path = root.parent / "tests" / "verify_update.py"
t = verify_path.read_text(encoding="utf-8")
t = t.replace("'1.54.0' and manifest['build'] == 55", "'1.55.0' and manifest['build'] == 56")
t = t.replace("'Replyzen-update-1.54.zip'", "'Replyzen-update-1.55.zip'")
t = t.replace("PASS: 1.54 version/build", "PASS: 1.55 version/build")
verify_path.write_text(t, encoding="utf-8")

# Final active-code guard: no Payment feature symbol/text may survive in Swift.
for swift_path in app.glob("*.swift"):
    lower = swift_path.read_text(encoding="utf-8").lower()
    leftovers = [token for token in ["payment", "überweisung", "banknote"] if token in lower]
    if leftovers:
        raise RuntimeError(f"Payment code remains in {swift_path.name}: {leftovers}")

print("Migrated ReplyZen to 1.55.0 / build 56: Payment removed, stable first-open WYSIWYG host")
