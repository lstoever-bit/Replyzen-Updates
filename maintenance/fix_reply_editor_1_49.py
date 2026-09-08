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
            // opened the reply window. Verify the actual UI state before using the
            // keyboard fallback so one action never creates duplicate reply windows.
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
new = '''            // Classic Outlook can show a perfectly usable reply body without
            // exposing it as a focusable AX body element. The editable Subject field
            // is reliable; one Tab from Subject enters the body. Give normal body
            // detection two attempts first, then use this deterministic fallback.
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

p = app / 'OutlookAccessibility.swift'
s = p.read_text()
marker = '''    func openReplyComposer(replyAll: Bool, from snapshot: Snapshot) -> Bool {
'''
insert = '''    func hasOpenedReplyComposer(since snapshot: Snapshot) -> Bool {
        guard let focused = focusedOutlookWindow() else { return false }

        // Detached compose windows are the normal Legacy Outlook behavior.
        if !containsSameElement(snapshot.windows, focused) {
            return true
        }

        // Some Outlook builds compose inline. Reuse the existing language-aware
        // compose-window detector (Send/Senden/Enviar) rather than treating a
        // read-only message web area as an editor.
        return looksLikeComposeWindow(focused)
    }

'''
s = replace_once(s, marker, insert + marker, 'reply composer marker')
p.write_text(s)

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
