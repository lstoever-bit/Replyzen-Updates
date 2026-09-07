from pathlib import Path
import sys

root = Path(sys.argv[1])


def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f"{label} not found")
    return text.replace(old, new, 1)

# Overlay: make the main mail editor materially larger, keep the action bar at
# the bottom, and remove the extra scrolling wrapper around the main form.
p = root / "app" / "OverlayView.swift"
s = p.read_text()
s = must_replace(
    s,
    '''        case .instruction:\n            ScrollView {\n                instructionView\n                    .frame(maxWidth: .infinity, alignment: .leading)\n                    .padding(.bottom, 6)\n            }\n''',
    '''        case .instruction:\n            instructionView\n                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)\n''',
    "instruction wrapper",
)
s = must_replace(
    s,
    '''                    height: 136,\n                    showsHTMLBadge: false\n''',
    '''                    height: 320,\n                    showsHTMLBadge: false\n''',
    "main rich editor height",
)

old_footer = '''            HStack {\n                Button("Schließen") { state.closeAction?() }\n                Spacer()\n                Button(primaryActionTitle) { state.generateAction?() }\n                    .keyboardShortcut(.defaultAction)\n                    .disabled(primaryActionDisabled)\n            }\n'''
new_footer = '''            Spacer(minLength: 12)\n\n            Divider()\n\n            HStack(spacing: 12) {\n                Button("Schließen") { state.closeAction?() }\n                    .controlSize(.large)\n\n                Spacer()\n\n                Button(primaryActionTitle) { state.generateAction?() }\n                    .buttonStyle(.borderedProminent)\n                    .controlSize(.large)\n                    .frame(minWidth: 170)\n                    .keyboardShortcut(.defaultAction)\n                    .disabled(primaryActionDisabled)\n            }\n            .padding(.top, 2)\n'''
s = must_replace(s, old_footer, new_footer, "bottom action bar")

# Remove the redundant status line under Mood/Compact/language to make the form cleaner.
old_status = '''            if state.outputMode == .reply || state.outputMode == .newMail {\n                HStack(spacing: 6) {\n                    Text("Mood: \\(state.replyTone.displayName)")\n                    Text("·")\n                    Text(state.newMailCompact ? "Compact" : "Normal")\n                    Text("·")\n                    Text("Sprache: \\(state.replyLanguage.displayName)")\n                }\n                .font(.caption)\n                .foregroundStyle(.secondary)\n            } else if state.outputMode == .calendar {\n                Text("Sprache: \\(state.replyLanguage.displayName)")\n                    .font(.caption)\n                    .foregroundStyle(.secondary)\n            } else {\n                HStack(spacing: 6) {\n                    Image(systemName: "doc.richtext")\n                    Text("PDF wird direkt von OpenAI gelesen")\n                }\n                .font(.caption)\n                .foregroundStyle(.secondary)\n            }\n\n'''
new_status = '''            if state.outputMode == .calendar {\n                Text("Sprache: \\(state.replyLanguage.displayName)")\n                    .font(.caption)\n                    .foregroundStyle(.secondary)\n            } else if state.outputMode == .payment {\n                HStack(spacing: 6) {\n                    Image(systemName: "doc.richtext")\n                    Text("PDF wird direkt von OpenAI gelesen")\n                }\n                .font(.caption)\n                .foregroundStyle(.secondary)\n            }\n\n'''
s = must_replace(s, old_status, new_status, "remove redundant mail status line")
p.write_text(s)

# Panel: give the mail form a little more room while still clamping to the visible screen.
p = root / "app" / "FloatingPanelController.swift"
s = p.read_text()
s = must_replace(
    s,
    '        panel.minSize = NSSize(width: 600, height: 420)\n',
    '        panel.minSize = NSSize(width: 680, height: 560)\n',
    "panel minimum size",
)
s = must_replace(
    s,
    '''            case .reply, .newMail:\n                return NSSize(width: 840, height: 760)\n''',
    '''            case .reply, .newMail:\n                return NSSize(width: 900, height: 800)\n''',
    "mail preferred size",
)
p.write_text(s)

# macOS menu bar: only the Replyzen logo, no wordmark. Mark it as a template image
# so macOS automatically renders it white in dark menu bars and black in light ones.
p = root / "app" / "AppDelegate.swift"
s = p.read_text()
old_status_item = '''    private func configureStatusItem() {\n        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)\n        if let url = Bundle.main.url(forResource: "ReplyzenLogo", withExtension: "png"),\n           let image = NSImage(contentsOf: url) {\n            image.size = NSSize(width: 16, height: 16)\n            item.button?.image = image\n        } else {\n            item.button?.image = NSImage(systemSymbolName: "envelope.badge", accessibilityDescription: "Replyzen")\n        }\n        item.button?.title = "Replyzen"\n        item.button?.imagePosition = .imageLeading\n        item.button?.font = .systemFont(ofSize: 13, weight: .semibold)\n        item.button?.toolTip = "Replyzen"\n\n        let menu = NSMenu()\n'''
new_status_item = '''    private func configureStatusItem() {\n        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)\n        if let url = Bundle.main.url(forResource: "ReplyzenLogo", withExtension: "png"),\n           let image = NSImage(contentsOf: url) {\n            image.size = NSSize(width: 18, height: 18)\n            image.isTemplate = true\n            item.button?.image = image\n        } else if let fallback = NSImage(systemSymbolName: "envelope.badge", accessibilityDescription: "Replyzen") {\n            fallback.isTemplate = true\n            item.button?.image = fallback\n        }\n        item.button?.title = ""\n        item.button?.imagePosition = .imageOnly\n        item.button?.toolTip = "Replyzen"\n\n        let menu = NSMenu()\n'''
s = must_replace(s, old_status_item, new_status_item, "menu bar icon only")
p.write_text(s)

# Version metadata.
p = root / "app" / "Info.plist"
s = p.read_text()
s = must_replace(s, '<string>1.28.0</string>', '<string>1.29.0</string>', "version")
s = must_replace(s, '<string>29</string>', '<string>30</string>', "build")
p.write_text(s)

# Update package metadata.
p = root / "Build-CI.sh"
s = p.read_text()
s = s.replace('Replyzen-update-1.28.zip', 'Replyzen-update-1.29.zip')
s = must_replace(
    s,
    '  "notes": "Replyzen 1.28: Das Outlook Overlay hat jetzt genau New, Reply und Decline. Das Replyzen Logo plus Name erscheinen in der macOS Menüleiste. Der kompakte WYSIWYG Editor sitzt direkt in der Mail Hauptansicht. Nach Erstellen wird kein zweites Vorschaufenster geöffnet, sondern die Mail wird direkt in Outlook vorbereitet. Fett, Kursiv und Listen werden als HTML und RTF an Outlook übergeben."\n',
    '  "notes": "Replyzen 1.29: Größeres WYSIWYG Textfeld in der Mail Hauptansicht, aufgeräumte GUI und feste Aktionsleiste unten mit Schließen links und Erstellen rechts. In der macOS Menüleiste erscheint nur noch das Replyzen Logo ohne Schriftzug; das Icon folgt automatisch dem Hell und Dunkelmodus."\n',
    "update notes",
)
p.write_text(s)
