from pathlib import Path
import runpy
import sys

root = Path(sys.argv[1])

# Reuse the already validated first half of v42. It updates AppState,
# KeyboardController, OutlookAccessibility and OverlayView before stopping at
# the old openWorkspace shape.
try:
    runpy.run_path(str(Path(__file__).resolve().parent.parent / "v42" / "patch.py"), run_name="__main__")
except SystemExit as exc:
    if "workspace reminder reset not found" not in str(exc):
        raise


def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f"{label} not found")
    return text.replace(old, new, 1)

# Apply the AppDelegate portion against the actual 1.29 source.
p = root / "app" / "AppDelegate.swift"
s = p.read_text()
old_status = '''        if let url = Bundle.main.url(forResource: "ReplyzenLogo", withExtension: "png"),\n           let image = NSImage(contentsOf: url) {\n            image.size = NSSize(width: 18, height: 18)\n            image.isTemplate = true\n            item.button?.image = image\n        } else if let fallback = NSImage(systemSymbolName: "envelope.badge", accessibilityDescription: "Replyzen") {\n            fallback.isTemplate = true\n            item.button?.image = fallback\n        }\n'''
new_status = '''        if let url = Bundle.main.url(forResource: "ReplyzenLogo", withExtension: "png"),\n           let source = NSImage(contentsOf: url),\n           let image = makeMenuBarTemplateIcon(from: source) {\n            item.button?.image = image\n        } else if let fallback = NSImage(systemSymbolName: "envelope.badge", accessibilityDescription: "Replyzen") {\n            fallback.isTemplate = true\n            item.button?.image = fallback\n        }\n'''
s = must_replace(s, old_status, new_status, "menu bar icon source")

anchor = '    private func configureHotKey() {\n'
helper = '''    private func makeMenuBarTemplateIcon(from source: NSImage) -> NSImage? {\n        let pixels = 36\n        guard let rep = NSBitmapImageRep(\n            bitmapDataPlanes: nil,\n            pixelsWide: pixels,\n            pixelsHigh: pixels,\n            bitsPerSample: 8,\n            samplesPerPixel: 4,\n            hasAlpha: true,\n            isPlanar: false,\n            colorSpaceName: .deviceRGB,\n            bytesPerRow: 0,\n            bitsPerPixel: 0\n        ) else { return nil }\n\n        NSGraphicsContext.saveGraphicsState()\n        if let context = NSGraphicsContext(bitmapImageRep: rep) {\n            NSGraphicsContext.current = context\n            context.imageInterpolation = .high\n            NSColor.white.setFill()\n            NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()\n            source.draw(\n                in: NSRect(x: 1, y: 1, width: pixels - 2, height: pixels - 2),\n                from: .zero,\n                operation: .sourceOver,\n                fraction: 1\n            )\n        }\n        NSGraphicsContext.restoreGraphicsState()\n\n        guard let data = rep.bitmapData else { return nil }\n        let rowBytes = rep.bytesPerRow\n        for y in 0..<pixels {\n            for x in 0..<pixels {\n                let i = y * rowBytes + x * 4\n                let r = Int(data[i])\n                let g = Int(data[i + 1])\n                let b = Int(data[i + 2])\n                let originalAlpha = Int(data[i + 3])\n                let luminance = (r * 30 + g * 59 + b * 11) / 100\n                let darkness = max(0, 255 - luminance)\n                let alpha = darkness * originalAlpha / 255\n                data[i] = 0\n                data[i + 1] = 0\n                data[i + 2] = 0\n                data[i + 3] = UInt8(alpha)\n            }\n        }\n\n        let image = NSImage(size: NSSize(width: 18, height: 18))\n        image.addRepresentation(rep)\n        image.isTemplate = true\n        return image\n    }\n\n'''
if anchor not in s:
    raise SystemExit("hotkey anchor not found")
s = s.replace(anchor, helper + anchor, 1)

s = must_replace(
    s,
    '''        state.instructionHTML = ""\n\n        guard keychain.loadAPIKey() != nil else {\n''',
    '''        state.instructionHTML = ""\n        state.reminderEnabled = false\n\n        guard keychain.loadAPIKey() != nil else {\n''',
    "workspace reminder reset",
)

# Reply and Decline both use Outlook Reply All (Command Shift R).
s = s.replace('self?.keyboard.sendCommandR()', 'self?.keyboard.sendCommandShiftR()')
s = s.replace('self.keyboard.sendCommandR()', 'self.keyboard.sendCommandShiftR()')

anchor = '    private func insertGeneratedText() {\n'
helper = '''    private func reminderBCCAddress() -> String? {\n        guard state.reminderEnabled else { return nil }\n        let day = state.reminderDay.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()\n        let time = state.reminderTime.trimmingCharacters(in: .whitespacesAndNewlines)\n        guard ["mon", "tue", "wed", "thu", "fri", "sat", "sun"].contains(day), !time.isEmpty else { return nil }\n        return "\\(day)\\(time)@fut.io"\n    }\n\n'''
if anchor not in s:
    raise SystemExit("insertGeneratedText anchor not found")
s = s.replace(anchor, helper + anchor, 1)

old_reply = '''            DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in\n                guard let self else { return }\n                self.keyboard.sendCommandV()\n                self.isRunningFlow = false\n'''
new_reply = '''            DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in\n                guard let self else { return }\n                if let reminder = self.reminderBCCAddress() {\n                    _ = self.outlook.setComposeBCCValue(reminder)\n                    _ = self.outlook.focusComposeBodyField()\n                    self.copyMailToPasteboard(plainText: reply, html: self.state.replyHTML)\n                }\n                self.keyboard.sendCommandV()\n                self.isRunningFlow = false\n'''
s = must_replace(s, old_reply, new_reply, "Reply reminder BCC")

s = must_replace(
    s,
    '''            let subjectDone = subject.isEmpty || self.outlook.setComposeSubjectValue(subject)\n            // Accessibility can set plain text directly, but rich formatting must be\n''',
    '''            let subjectDone = subject.isEmpty || self.outlook.setComposeSubjectValue(subject)\n            let reminderDone: Bool\n            if let reminder = self.reminderBCCAddress() {\n                reminderDone = self.outlook.setComposeBCCValue(reminder)\n            } else {\n                reminderDone = true\n            }\n            // Accessibility can set plain text directly, but rich formatting must be\n''',
    "New Mail reminder BCC attempt",
)
s = must_replace(
    s,
    '''            if html.isEmpty, self.outlook.setComposeBodyValue(body) {\n                self.finishNewMailInsertion()\n                return\n            }\n''',
    '''            if html.isEmpty, reminderDone, self.outlook.setComposeBodyValue(body) {\n                self.finishNewMailInsertion()\n                return\n            }\n''',
    "New Mail reminder direct body",
)
s = must_replace(
    s,
    '''            if attempt < 2 {\n                self.populateNewMailDraft(subject: subject, body: body, html: html, attempt: attempt + 1)\n                return\n            }\n''',
    '''            if attempt < 2 {\n                self.populateNewMailDraft(subject: subject, body: body, html: html, attempt: attempt + 1)\n                return\n            }\n\n            if !reminderDone, let reminder = self.reminderBCCAddress() {\n                _ = self.outlook.setComposeBCCValue(reminder)\n            }\n''',
    "New Mail reminder final attempt",
)
p.write_text(s)

# Version/build metadata.
p = root / "app" / "Info.plist"
s = p.read_text()
s = must_replace(s, '<string>1.29.0</string>', '<string>1.30.0</string>', "Info version")
s = must_replace(s, '<string>30</string>', '<string>31</string>', "Info build")
p.write_text(s)

p = root / "Build-CI.sh"
s = p.read_text()
s = s.replace('Replyzen-update-1.29.zip', 'Replyzen-update-1.30.zip')
s = must_replace(
    s,
    '"notes": "Replyzen 1.29: Größeres WYSIWYG Textfeld in der Mail Hauptansicht, aufgeräumte GUI und feste Aktionsleiste unten mit Schließen links und Erstellen rechts. In der macOS Menüleiste erscheint nur noch das Replyzen Logo ohne Schriftzug; das Icon folgt automatisch dem Hell und Dunkelmodus."',
    '"notes": "Replyzen 1.30: Reply verwendet immer Reply All. Optionaler Reminder in der Mail Ansicht mit Mo bis So und Uhrzeit 0:00 bis 24:00; bei Aktivierung wird automatisch z. B. wed12:00@fut.io in BCC gesetzt. Das macOS Menüleisten Icon wird aus dem Replyzen App Logo als transparente Template Maske erzeugt, damit kein weißes Quadrat mehr erscheint."',
    "Build notes",
)
p.write_text(s)
