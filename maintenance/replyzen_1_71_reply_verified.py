#!/usr/bin/env python3
"""Apply the narrowly scoped Reply 1.71 transport integration; fail closed on drift."""
from pathlib import Path
import json
import plistlib
import sys

root = Path(sys.argv[1])
app = root / 'app'
repo = root.parent
info_path = app / 'Info.plist'
info = plistlib.loads(info_path.read_bytes())
version = (info.get('CFBundleShortVersionString'), str(info.get('CFBundleVersion')))
if version not in [('1.70.0', '71'), ('1.71.0', '72')]:
    raise SystemExit(f'Unexpected canonical source {version}; refusing to modify')

def once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f'Expected one migration anchor: {old[:100]!r}')
    return text.replace(old, new, 1)

delegate_path = app / 'AppDelegate.swift'
delegate = delegate_path.read_text()
if version == ('1.71.0', '72'):
    assert 'activeReplyInsertion = OutlookReplyInsertion(' in delegate
    assert 'self.finishNewMailInsertion()' in delegate
    assert (app / 'ReplyInsertionPolicy.swift').is_file()
    assert (app / 'OutlookReplyInsertion.swift').is_file()
    print('ReplyZen 1.71 integration already applied')
    raise SystemExit(0)

start = delegate.index('    private func insertReply() {')
end = delegate.index('    private func insertForwardDraft() {', start)
old_reply = delegate[start:end]
assert 'self.outlook.focusComposeBodyField()' in old_reply
assert 'self.populateReplyDraft(reply: reply, html: self.state.replyHTML, attempt: 0)' in old_reply
# Keep initial validation and panel setup. Replace only the old unverified async insertion.
cut = old_reply.index('        let replyAll = state.replyScope == .all')
new_reply = old_reply[:cut] + '''        let replyAll = state.replyScope == .all
        let html = state.replyHTML
        copyMailToPasteboard(plainText: reply, html: html)
        panel.hide()
        outlook.activateOutlook(pid: snapshot.pid)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isRunningFlow, self.state.stage == .inserting else { return }
            self.populateReplyDraft(reply: reply, html: html, snapshot: snapshot, replyAll: replyAll)
        }
    }

    private func populateReplyDraft(reply: String, html: String,
                                    snapshot: OutlookAccessibility.Snapshot, replyAll: Bool) {
        activeReplyInsertion = OutlookReplyInsertion(
            outlook: outlook, snapshot: snapshot, replyAll: replyAll,
            note: reply, html: html, reminder: reminderBCCAddress()
        ) { [weak self] errorCode in
            guard let self else { return }
            self.activeReplyInsertion = nil
            if let errorCode {
                self.copyMailToPasteboard(plainText: reply, html: html)
                self.showError(L10n.source("ReplyZen konnte das Einfuegen der Antwort nicht bestaetigen (Diagnose: {0}). Bitte pruefe den geoeffneten Entwurf. Dein Text bleibt in der Zwischenablage.", errorCode))
            } else {
                // Only called after the note was read back from the same draft.
                self.finishNewMailInsertion()
            }
        }
        activeReplyInsertion?.start()
    }

'''
new_reply = once(new_reply, '    private func insertReply() {\n', '    private func insertReply() {\n        guard activeReplyInsertion == nil else { return }\n')
delegate = delegate[:start] + new_reply + delegate[end:]
delegate = once(delegate, '    private var isRunningFlow = false\n', '    private var isRunningFlow = false\n    private var activeReplyInsertion: OutlookReplyInsertion?\n')
for anchor in ['    private func closePanel() {\n', '    private func deactivateForOutlook() {\n']:
    delegate = once(delegate, anchor, anchor + '        activeReplyInsertion?.cancel()\n        activeReplyInsertion = nil\n')
delegate_path.write_text(delegate)

# Retain all existing regression checks, adapting only checks for the replaced Reply path.
p = repo / 'tests/test_source_contracts.py'
s = p.read_text().replace('"1.70.0"', '"1.71.0"')
s = once(s, 'self.assertEqual(info["CFBundleVersion"], "71")', 'self.assertEqual(info["CFBundleVersion"], "72")')
s = once(s, '        self.assertIn("openReplyComposer(replyAll: replyAll, from: snapshot)", reply)\n', '        self.assertIn("OutlookReplyInsertion(", reply)\n        self.assertIn("openReplyComposer(replyAll: replyAll, from: snapshot)", self.read("OutlookReplyInsertion.swift"))\n')
s = once(s, '        self.assertIn("hasOpenedReplyComposer(since: snapshot)", reply)\n', '        self.assertIn("ReplyInsertionPolicy.isSendControl", self.read("OutlookReplyInsertion.swift"))\n')
s = once(s, '        self.assertIn("focusComposeBodyField()", reply)\n', '        self.assertIn("activeReplyInsertion?.start()", reply)\n')
s = once(s, '        self.assertLess(reply.index("setComposeBCCValue(reminder)"), reply.index("focusComposeBodyField()"))\n', '        self.assertIn("reminder: reminderBCCAddress()", reply)\n        self.assertIn("setComposeBCCValue(reminder)", self.read("OutlookReplyInsertion.swift"))\n')
p.write_text(s)
p = repo / 'tests/verify_update.py'
s = p.read_text().replace('1.70', '1.71').replace("manifest['build'] == 71", "manifest['build'] == 72")
p.write_text(s)

key = 'ReplyZen konnte das Einfuegen der Antwort nicht bestaetigen (Diagnose: {0}). Bitte pruefe den geoeffneten Entwurf. Dein Text bleibt in der Zwischenablage.'
p = app / 'Resources/Localization.json'
catalog = json.loads(p.read_text())
catalog[key] = {
    'de': 'ReplyZen konnte das Einf\u00fcgen der Antwort nicht best\u00e4tigen (Diagnose: {0}). Bitte pr\u00fcfe den ge\u00f6ffneten Entwurf. Dein Text bleibt in der Zwischenablage.',
    'en-US': 'ReplyZen could not confirm insertion of the reply (diagnostic: {0}). Please check the open draft. Your text remains on the clipboard.',
    'es': 'ReplyZen no pudo confirmar la inserci\u00f3n de la respuesta (diagn\u00f3stico: {0}). Revisa el borrador abierto. Tu texto sigue en el portapapeles.'
}
p.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n')
notes = {
    'de': 'ReplyZen 1.71: Antworten nutzt jetzt einen separaten Ablauf mit Pr\u00fcfung des Antwortfensters, des tats\u00e4chlichen Editor-Fokus und des eingef\u00fcgten Textes. Senden/Empfangen und der Lesebereich gelten nicht mehr als Antworteditor. Keine blinden Tab-Einf\u00fcgungen und keine Erfolgsmeldung allein nach Cmd+V. Neue Mail und Weiterleiten bleiben unver\u00e4ndert. Automatisierte Tests und Build-Pr\u00fcfung ersetzen keinen Live-Test in Outlook.',
    'en-US': 'ReplyZen 1.71: Replies now use an isolated workflow that checks the draft window, real editor focus and inserted text. Send/Receive and the read pane no longer count as a reply composer. Removes blind Tab pasting and success immediately after Cmd+V. New Mail and Forward are unchanged. Automated tests and build verification do not replace live Outlook testing.',
    'es': 'ReplyZen 1.71: Las respuestas usan un flujo separado que comprueba el borrador, el foco real del editor y el texto insertado. Enviar/recibir y el panel de lectura no se consideran editores. Se elimina el pegado a ciegas tras Tab. Nuevo correo y Reenviar no cambian. Las pruebas automatizadas no sustituyen una prueba real en Outlook.'
}
(root / 'Release-notes.txt').write_text(notes['de'] + '\n')
(root / 'Release-notes.localized.json').write_text(json.dumps(notes, ensure_ascii=False, indent=2) + '\n')
info['CFBundleShortVersionString'] = '1.71.0'
info['CFBundleVersion'] = '72'
info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
# Catch escaping mistakes before Swift or any packaging step.
compile((repo / 'tests/test_source_contracts.py').read_text(), 'test_source_contracts.py', 'exec')
print('Applied ReplyZen 1.71 / build 72 verified Reply workflow')
