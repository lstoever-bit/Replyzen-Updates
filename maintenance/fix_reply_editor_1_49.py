#!/usr/bin/env python3
from pathlib import Path
import plistlib
import json
import sys

root = Path(sys.argv[1])
app = root / 'app'
info_path = app / 'Info.plist'
info = plistlib.loads(info_path.read_bytes())
if info['CFBundleShortVersionString'] == '1.49.0':
    print('ReplyZen 1.49 migration already applied')
    raise SystemExit(0)
if info['CFBundleShortVersionString'] != '1.48.0':
    raise SystemExit('Unexpected source version; refusing to modify')

def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'Expected exactly one {label}; found {count}')
    return text.replace(old, new, 1)

# 1) Do not trust AXPress alone. Verify that Outlook actually opened a different
# compose window before using the keyboard shortcut, preventing duplicate replies.
p = app / 'AppDelegate.swift'
s = p.read_text()
old = '''        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self else { return }
            let openedThroughAccessibility = self.outlook.openReplyComposer(replyAll: replyAll, from: snapshot)
            if !openedThroughAccessibility {
                if replyAll { self.keyboard.sendCommandShiftR() }
                else { self.keyboard.sendCommandR() }
            }
            self.populateReplyDraft(reply: reply, html: self.state.replyHTML, attempt: 0)
        }
'''
new = '''        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self else { return }
            _ = self.outlook.openReplyComposer(replyAll: replyAll, from: snapshot)

            // Legacy Outlook can report a failed AXPress even though it already
            // opened the reply window. Verify the UI state before falling back to
            // the keyboard shortcut so one click never creates two reply windows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                if !self.outlook.hasOpenedReplyComposer(since: snapshot) {
                    if replyAll { self.keyboard.sendCommandShiftR() }
                    else { self.keyboard.sendCommandR() }
                }
                self.populateReplyDraft(reply: reply, html: self.state.replyHTML, attempt: 0)
            }
        }
'''
s = replace_once(s, old, new, 'reply opening block')

old = '''            if attempt < 10 {
                self.populateReplyDraft(reply: reply, html: html, attempt: attempt + 1)
                return
            }

            self.copyMailToPasteboard(plainText: reply, html: html)
'''
new = '''            // Classic Outlook frequently exposes the visible reply body without
            // exposing it as a focusable AXTextArea/AXWebArea. Its editable Subject
            // field is reliable; one Tab from Subject enters the reply body. Wait for
            // two normal body-detection attempts first, then use this deterministic
            // fallback and paste at the top of the reply editor.
            if attempt >= 2, self.outlook.focusComposeSubjectField() {
                self.keyboard.sendTab()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                    guard let self else { return }
                    self.keyboard.sendCommandUp()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                        guard let self else { return }
                        self.copyMailToPasteboard(plainText: reply, html: html)
                        self.keyboard.sendCommandV()
                        self.finishNewMailInsertion()
                    }
                }
                return
            }

            if attempt < 12 {
                self.populateReplyDraft(reply: reply, html: html, attempt: attempt + 1)
                return
            }

            self.copyMailToPasteboard(plainText: reply, html: html)
'''
s = replace_once(s, old, new, 'reply body fallback block')
p.write_text(s)

# 2) Detect an actually opened compose window rather than relying on AX action status.
p = app / 'OutlookAccessibility.swift'
s = p.read_text()
marker = '''    func openReplyComposer(replyAll: Bool, from snapshot: Snapshot) -> Bool {
'''
insert = '''    func hasOpenedReplyComposer(since snapshot: Snapshot) -> Bool {
        guard let focused = focusedOutlookWindow() else { return false }

        // A detached reply window is the normal Legacy Outlook behavior and is the
        // strongest signal. CFEqual is stable for AXUIElement window identities.
        if !containsSameElement(snapshot.windows, focused) {
            return true
        }

        // Some Outlook builds keep compose UI in the same window. In that case only
        // treat an explicitly labelled editable Subject field as a compose signal;
        // a read-only message web area alone must not count.
        return hasExplicitComposeSubjectField(in: focused)
    }

    private func hasExplicitComposeSubjectField(in window: AXUIElement) -> Bool {
        var stack: [AXUIElement] = [window]
        var visited = 0
        while let element = stack.popLast(), visited < 14_000 {
            visited += 1
            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" {
                let meta = composeMetadata(for: element)
                if (meta.contains("subject") || meta.contains("betreff") || meta.contains("asunto")),
                   isValueSettable(element) {
                    return true
                }
            }
            for child in children(of: element).reversed() { stack.append(child) }
        }
        return false
    }

'''
s = replace_once(s, marker, insert + marker, 'reply composer marker')
s = replace_once(s,
'''                if meta.contains("subject") || meta.contains("betreff") {
                    return element
                }
''',
'''                if meta.contains("subject") || meta.contains("betreff") || meta.contains("asunto") {
                    return element
                }
''', 'subject label matcher')
p.write_text(s)

# Version / build.
info['CFBundleShortVersionString'] = '1.49.0'
info['CFBundleVersion'] = '50'
info_path.write_bytes(plistlib.dumps(info, sort_keys=False))

notes = {
    'de': 'ReplyZen 1.49: Reply und Reply All wurden für Legacy Outlook robuster gemacht. ReplyZen prüft jetzt, ob Outlook wirklich bereits ein Antwortfenster geöffnet hat, bevor ein Tastatur-Fallback ausgelöst wird; dadurch werden doppelte Antwortfenster vermieden. Wenn Outlook den sichtbaren Antwortbereich nicht über Accessibility meldet, setzt ReplyZen den Text zuverlässig über Betreff → Tab in den Antworteditor ein.',
    'en-US': 'ReplyZen 1.49: Reply and Reply All are more robust in Legacy Outlook. ReplyZen now verifies whether Outlook actually opened a reply window before using the keyboard fallback, preventing duplicate reply windows. If Outlook does not expose the visible reply body through Accessibility, ReplyZen reliably enters it via Subject → Tab and inserts the draft.',
    'es': 'ReplyZen 1.49: Responder y Responder a todos son ahora más fiables en Outlook clásico. ReplyZen comprueba si Outlook ya ha abierto realmente una ventana de respuesta antes de usar el atajo de teclado, evitando ventanas duplicadas. Si Outlook no expone el cuerpo visible mediante Accesibilidad, ReplyZen entra de forma fiable mediante Asunto → Tab e inserta el borrador.'
}
(root / 'Release-notes.localized.json').write_text(json.dumps(notes, ensure_ascii=False, indent=2) + '\n')
(root / 'Release-notes.txt').write_text(notes['de'] + '\n')

# Keep existing regression guards aligned and assert both fixes exist.
contracts = root.parent / 'tests' / 'test_source_contracts.py'
t = contracts.read_text()
t = t.replace("'1.48.0'", "'1.49.0'").replace("'49'", "'50'")
needle = "        self.assertIn('openSelectedMessageWindowIfNeeded', self.read('OutlookAccessibility.swift'))\n"
addition = needle + "        self.assertIn('hasOpenedReplyComposer(since: snapshot)', app)\n        self.assertIn('focusComposeSubjectField()', app)\n        self.assertIn('if attempt >= 2', app)\n"
t = replace_once(t, needle, addition, 'reply regression assertions')
contracts.write_text(t)

verify = root.parent / 'tests' / 'verify_update.py'
t = verify.read_text()
t = t.replace("'1.48.0' and manifest['build'] == 49", "'1.49.0' and manifest['build'] == 50")
t = t.replace("'Replyzen-update-1.48.zip'", "'Replyzen-update-1.49.zip'")
t = t.replace('PASS: 1.48 version/build', 'PASS: 1.49 version/build')
verify.write_text(t)

print('Migrated ReplyZen to 1.49.0 / build 50')
