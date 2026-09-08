#!/usr/bin/env python3
"""Checked one-time migration. The workflow saves tested canonical Swift sources."""
import hashlib
from pathlib import Path
import plistlib
import sys

root = Path(sys.argv[1])
app = root / 'app'
info = plistlib.loads((app / 'Info.plist').read_bytes())
if info['CFBundleShortVersionString'] == '1.46.0':
    for name in ['WorkspaceComponents.swift', 'MailWorkspaceView.swift', 'EditorToolbar.swift']:
        if not (app / name).is_file():
            raise SystemExit('Incomplete 1.46 migration')
    print('1.46 source already migrated')
    raise SystemExit(0)
if info['CFBundleShortVersionString'] != '1.45.0':
    raise SystemExit('Unexpected source version; refusing to overwrite newer work')

expected = {
    'OverlayView.swift': 'dc073d2d9d33a3b9c1f076c3e26a98e359d3bf1f',
    'RichTextMailEditor.swift': 'dbf5c64f54f88213a55f0204d378d18572ee6b95',
    'FloatingPanelController.swift': '5a328802335d73d7600d342e473f3dbc95e8c656',
}
texts = {}
for name, sha in expected.items():
    data = (app / name).read_bytes()
    actual = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
    if actual != sha:
        raise SystemExit('Source changed since review: ' + name)
    texts[name] = data.decode('utf-8')

def once(s, before, after):
    if s.count(before) != 1:
        raise RuntimeError('Expected one source marker: ' + before[:100])
    return s.replace(before, after, 1)

s = texts['OverlayView.swift']
a, b = s.index('    var body: some View {'), s.index('    @ViewBuilder')
s = s[:a] + '''    var body: some View {
        VStack(spacing: 0) {
            if isWorkspace {
                WorkspaceHeader(state: state)
                Divider()
                content
            } else {
                content.padding(28)
            }
        }
        .frame(minWidth: 590, minHeight: 390)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var isWorkspace: Bool {
        state.stage == .instruction || state.stage == .preview ||
        state.stage == .calendarPreview || state.stage == .paymentPreview
    }

''' + s[b:]
s = once(s, '''        case .instruction:
            instructionView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
''', '''        case .instruction:
            MailWorkspaceView(state: state)
''')
s = once(s, '''        case .preview:
            ScrollView {
                previewView
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 6)
            }
''', '''        case .preview:
            MailDraftPreviewView(state: state)
''')
for kind in ['calendar', 'payment']:
    old = '''        case .KINDPreview:
            ScrollView {
                KINDPreviewView
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
'''.replace('KIND', kind)
    new = '''        case .KINDPreview:
            ScrollView {
                KINDPreviewView
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { KINDFooter }
'''.replace('KIND', kind)
    s = once(s, old, new)
# Old compose/preview helpers are replaced by the workspace components.
a = s.index('    private var instructionView: some View {')
b = s.index('    private var paymentPreviewView: some View {', a)
s = s[:a] + s[b:]
payment_bar = '''            HStack {
                Button("Zurück") { state.stage = .instruction }
                Spacer()
                Button("Überweisungsdaten kopieren") { state.copyPaymentAction?() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.paymentRecipient.isEmpty && state.paymentIBAN.isEmpty && state.paymentAmount.isEmpty)
            }
'''
calendar_bar = '''            HStack {
                Button("Zurück") { state.stage = .instruction }
                Spacer()
                Button("Im Kalender anlegen") { state.createCalendarAction?() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.calendarTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.calendarEnd <= state.calendarStart || state.selectedCalendarID.isEmpty || state.googleConnectedEmail.isEmpty)
            }
'''
s = once(s, payment_bar, '')
s = once(s, calendar_bar, '')
footers = '''    private var paymentFooter: some View {
        WorkspaceActionBar(
            secondaryTitle: "Zurück", primaryTitle: "Überweisungsdaten kopieren",
            hint: "Es wird keine Zahlung ausgelöst.",
            disabled: state.paymentRecipient.isEmpty && state.paymentIBAN.isEmpty && state.paymentAmount.isEmpty,
            secondaryAction: { state.stage = .instruction },
            primaryAction: { state.copyPaymentAction?() }
        )
    }

    private var calendarFooter: some View {
        WorkspaceActionBar(
            secondaryTitle: "Zurück", primaryTitle: "Im Kalender anlegen",
            hint: "Zeit und Zielkalender prüfen.",
            disabled: state.calendarTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.calendarEnd <= state.calendarStart || state.selectedCalendarID.isEmpty || state.googleConnectedEmail.isEmpty,
            secondaryAction: { state.stage = .instruction },
            primaryAction: { state.createCalendarAction?() }
        )
    }

'''
s = once(s, '    private var previewTitle: String {', footers + '    private var previewTitle: String {')
s = once(s, '''            Text(state.errorMessage)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
''', '''            ScrollView {
                Text(state.errorMessage)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
''')
texts['OverlayView.swift'] = s

s = texts['RichTextMailEditor.swift']
s = once(s, '    weak var textView: NSTextView?\n', '''    weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private var zoomObservation: NSKeyValueObservation?
    @Published private(set) var zoomPercent = 130

    func attachZoom(to scrollView: NSScrollView) {
        self.scrollView = scrollView
        zoomObservation = scrollView.observe(\\.magnification, options: [.new]) { [weak self, weak scrollView] _, _ in
            // Avoid publishing from inside a SwiftUI/AppKit update.
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self, let scrollView, self.scrollView === scrollView else { return }
                let percent = Int((scrollView.magnification * 100).rounded())
                if percent != self.zoomPercent { self.zoomPercent = percent }
            }
        }
    }

    func setZoom(percent: Int) {
        guard let scrollView else { return }
        let scale = min(scrollView.maxMagnification, max(scrollView.minMagnification, CGFloat(percent) / 100))
        scrollView.magnification = scale
        // Visual zoom never changes NSTextStorage fonts, plain text or HTML.
    }
''')
a = s.index('struct RichTextMailEditor: View {')
b = s.index('private final class RichTextEditorTextView:', a)
s = s[:a] + '''struct RichTextMailEditor: View {
    @Binding var plainText: String
    @Binding var html: String
    var height: CGFloat? = 176
    var showsHTMLBadge: Bool = true
    @StateObject private var controller = RichTextEditorController()

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(controller: controller)
            Divider()
            RichTextEditorBridge(plainText: $plainText, html: $html, controller: controller)
                .frame(minHeight: height == nil ? 80 : nil, maxHeight: .infinity)
        }
        .frame(height: height)
        .frame(maxHeight: height == nil ? .infinity : nil)
        .modifier(WorkspaceCard())
    }
}

''' + s[b:]
s = once(s, '        scrollView.magnification = Self.editorMagnification\n', '''        scrollView.magnification = Self.editorMagnification
        scrollView.identifier = NSUserInterfaceItemIdentifier("replyzen.mailEditor")
        controller.attachZoom(to: scrollView)
''')
texts['RichTextMailEditor.swift'] = s
s = texts['FloatingPanelController.swift']
s = once(s, 'panel.title = "Replyzen"', 'panel.title = ReplyZenBrand.displayName')
s = once(s, 'return NSSize(width: 900, height: 710)', 'return NSSize(width: 900, height: 740)')
s = once(s, 'return NSSize(width: 780, height: 560)', 'return NSSize(width: 900, height: 740)')
texts['FloatingPanelController.swift'] = s

info['CFBundleShortVersionString'] = '1.46.0'
info['CFBundleVersion'] = '47'
# Prepare test adjustments before writing any source file.
test_path = root.parent / 'tests' / 'test_source_contracts.py'
test_text = test_path.read_text().replace("'1.45.0'", "'1.46.0'")
test_text = once(test_text, "self.assertEqual(info['CFBundleVersion'], '46')", "self.assertEqual(info['CFBundleVersion'], '47')")
for name, text in texts.items():
    (app / name).write_text(text, encoding='utf-8')
(app / 'Info.plist').write_bytes(plistlib.dumps(info, sort_keys=False))
test_path.write_text(test_text, encoding='utf-8')
print('Migrated GUI to 1.46.0 / build 47; services, identities and typography unchanged')
