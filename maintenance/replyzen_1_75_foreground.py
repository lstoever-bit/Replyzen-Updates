#!/usr/bin/env python3
"""Prepare Reply text before focus handoff; retain the existing write safeguards."""
from pathlib import Path
import json
import plistlib
import sys

root = Path(sys.argv[1])
app = root / 'app'
repo = root.parent
info_path = app / 'Info.plist'
info = plistlib.loads(info_path.read_bytes())
version = (info['CFBundleShortVersionString'], str(info['CFBundleVersion']))
if version not in [('1.74.0', '75'), ('1.75.0', '76')]:
    raise SystemExit(f'Unexpected source version {version}')

def once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f'Expected one anchor, found {text.count(old)}: {old[:120]!r}')
    return text.replace(old, new, 1)

if version == ('1.75.0', '76'):
    assert 'holdUntilOutlookOwnsForeground()' in (app / 'OutlookReplyInsertion.swift').read_text()
    assert 'preparedPayload: preparedPayload' in (app / 'AppDelegate.swift').read_text()
    print('ReplyZen 1.75 already integrated')
    raise SystemExit(0)

untouched = ['OpenAIClient.swift', 'NewMailSubject.swift', 'MailPromptBuilder.swift',
             'OutlookAccessibility.swift', 'KeyboardController.swift',
             'ReplyInsertionPolicy.swift', 'ReplyWindowTracker.swift',
             'FloatingPanelController.swift', 'OutlookToolbarButtonController.swift']
originals = {name: (app / name).read_bytes() for name in untouched}

p = app / 'MailTypography.swift'
s = p.read_text()
s = once(s, '''        let value = payload(plainText: plainText, html: html)
        let item = NSPasteboardItem()
''', '''        write(payload(plainText: plainText, html: html), to: pasteboard)
    }

    /// Only publishes already-rendered formats. No HTML import or run-loop work
    /// belongs between checking Outlook focus and issuing its Paste command.
    static func write(_ value: Payload, to pasteboard: NSPasteboard = .general) {
        let item = NSPasteboardItem()
''')
p.write_text(s)

p = app / 'AppDelegate.swift'
s = p.read_text()
start = s.index('    private func insertReply() {')
end = s.index('    private func insertForwardDraft() {', start)
before, reply, after = s[:start], s[start:end], s[end:]
reply = once(reply, '''        let html = state.replyHTML
        copyMailToPasteboard(plainText: reply, html: html)
        panel.hide()
''', '''        let html = state.replyHTML
        // Finish all AppKit HTML/RTF conversion while ReplyZen still owns focus.
        let preparedPayload = MailTypography.payload(
            plainText: reply + "\\n\\n", html: html.isEmpty ? "" : html + "<br><br>")
        MailTypography.write(preparedPayload)
        panel.hide()
''')
reply = once(reply, 'self.populateReplyDraft(reply: reply, html: html, snapshot: snapshot, replyAll: replyAll)',
             'self.populateReplyDraft(reply: reply, html: html, snapshot: snapshot, replyAll: replyAll, preparedPayload: preparedPayload)')
reply = once(reply, 'snapshot: OutlookAccessibility.Snapshot, replyAll: Bool) {',
             'snapshot: OutlookAccessibility.Snapshot, replyAll: Bool, preparedPayload: MailTypography.Payload) {')
reply = once(reply, '            note: reply, html: html, reminder: reminderBCCAddress()\n',
             '            note: reply, html: html, reminder: reminderBCCAddress(),\n            preparedPayload: preparedPayload\n')
reply = once(reply, '                self.copyMailToPasteboard(plainText: reply, html: html)\n',
             '                MailTypography.write(preparedPayload)\n')
p.write_text(before + reply + after)
assert p.read_text()[p.read_text().index('    private func insertForwardDraft() {'):] == after

p = app / 'OutlookReplyInsertion.swift'
s = p.read_text()
s = once(s, '    private let html: String\n', '    private let html: String\n    private let preparedPayload: MailTypography.Payload\n    private var foregroundGuard = ReplyForegroundGuard()\n')
s = once(s, '         replyAll: Bool, note: String, html: String, reminder: String?,\n',
             '         replyAll: Bool, note: String, html: String, reminder: String?,\n         preparedPayload: MailTypography.Payload,\n')
s = once(s, '        self.html = html\n', '        self.html = html\n        self.preparedPayload = preparedPayload\n')
s = once(s, '''    private func scheduleTick() {
        DispatchQueue.main.asyncAfter''', '''    private func scheduleTick() {
        guard !cancelled else { return }
        DispatchQueue.main.asyncAfter''')
s = once(s, '''        let observation = observe()
        guard var currentState = state else { return }
''', '''        // Pause the SAME draft/state for a bounded internal activation handoff.
        // A different external app or an intentional ReplyZen window still aborts.
        guard holdUntilOutlookOwnsForeground() else { scheduleTick(); return }
        let observation = observe()
        guard observation.active else {
            // Ownership can change during an AX read. Reclassify instead of
            // feeding a transient self-activation into the terminal state error.
            _ = holdUntilOutlookOwnsForeground()
            scheduleTick()
            return
        }
        guard var currentState = state else { return }
''')
s = once(s, '            MailTypography.write(plainText: note + "\\n\\n", html: html.isEmpty ? "" : html + "<br><br>")',
             '            MailTypography.write(preparedPayload)')
helper = '''    private func holdUntilOutlookOwnsForeground() -> Bool {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let owner: ReplyForegroundGuard.Owner
        if frontmostPID == snapshot.pid { owner = .outlook }
        else if frontmostPID == ProcessInfo.processInfo.processIdentifier { owner = .replyzen }
        else if frontmostPID == nil { owner = .unavailable }
        else { owner = .other }
        let ownInteractiveWindow = NSApp.windows.contains {
            $0.isVisible && ($0.isKeyWindow || $0.isMainWindow)
        }
        let decision = foregroundGuard.next(owner: owner,
            ownInteractiveWindow: ownInteractiveWindow,
            now: ProcessInfo.processInfo.systemUptime)
        switch decision {
        case .ready: return true
        case .wait: return false
        case .handoff:
            // This method is called only for ReplyZen's own hidden process.
            // Do not reopen a reply, reset the paste state or touch a different app.
            Self.activateForReply(pid: snapshot.pid)
            return false
        case .abort(let code):
            finish(code)
            return false
        }
    }

'''
s = once(s, '    private func finish(_ errorCode: String?) {\n', helper + '    private func finish(_ errorCode: String?) {\n')
p.write_text(s)

info['CFBundleShortVersionString'] = '1.75.0'
info['CFBundleVersion'] = '76'
info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
p = repo / 'tests/test_source_contracts.py'
s = p.read_text().replace('"1.74.0"', '"1.75.0"')
s = once(s, 'self.assertEqual(info["CFBundleVersion"], "75")', 'self.assertEqual(info["CFBundleVersion"], "76")')
p.write_text(s)
p = repo / 'tests/verify_update.py'
s = p.read_text().replace('1.74', '1.75').replace("manifest['build'] == 75", "manifest['build'] == 76")
p.write_text(s)
notes = {
    'de': 'ReplyZen 1.75: Der Antworttext wird vollstaendig formatiert, bevor der Fokus an Outlook geht. Zwischen Fokuspruefung und Einfuegen findet keine HTML-Umwandlung mehr statt. Ein kurzzeitiger Fokuswechsel zu ReplyZens verborgenem Prozess wird begrenzt abgefangen, ohne einen neuen Entwurf oder eine zweite Einfuegung zu erzeugen. Ein Wechsel zu einer anderen App bricht weiterhin sicher ab. Neue Mail und Weiterleitung unveraendert. Der gemeldete APPFOCUS-Abbruch ist eingegrenzt, sein konkreter Ausloeser auf dem Nutzer-Mac bleibt unbestaetigt.',
    'en-US': 'ReplyZen 1.75: Render the reply payload before handing focus to Outlook; no HTML conversion between the focus check and paste. Recover bounded transient activation of the hidden ReplyZen process without opening another draft or pasting twice. Switching to another app still aborts safely. New Mail and Forward are unchanged. The reported APPFOCUS failure is narrowed down; its precise trigger on the user Mac remains unconfirmed.',
    'es': 'ReplyZen 1.75: Prepara el texto antes de ceder el foco a Outlook y evita convertir HTML durante el pegado. Recupera de forma limitada el foco del proceso oculto de ReplyZen sin abrir otro borrador ni pegar dos veces. Cambiar a otra aplicacion sigue cancelando la operacion. Nuevo correo y Reenviar no cambian. Falta validar la causa concreta en el Mac del usuario.'
}
(root / 'Release-notes.txt').write_text(notes['de'] + '\n')
(root / 'Release-notes.localized.json').write_text(json.dumps(notes, ensure_ascii=False, indent=2) + '\n')
for name, original in originals.items():
    assert (app / name).read_bytes() == original, name
compile((repo / 'tests/test_source_contracts.py').read_text(), 'contracts', 'exec')
print('Integrated 1.75 / build 76; nine unrelated sources and Forward/New Mail transports unchanged')
