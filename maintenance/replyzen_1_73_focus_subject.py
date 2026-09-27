#!/usr/bin/env python3
"""Narrow, guarded integration for the two screenshot-reported regressions."""
from pathlib import Path
import json
import plistlib
import sys

root = Path(sys.argv[1]); repo = root.parent; app = root / 'app'
info_path = app / 'Info.plist'; info = plistlib.loads(info_path.read_bytes())
version = (info['CFBundleShortVersionString'], str(info['CFBundleVersion']))
if version == ('1.73.0', '74'):
    assert 'activateForReply' in (app / 'OutlookReplyInsertion.swift').read_text()
    assert 'NewMailSubject.resolve' in (app / 'OpenAIClient.swift').read_text()
    print('ReplyZen 1.73 already integrated'); raise SystemExit(0)
if version != ('1.72.0', '73'):
    raise SystemExit(f'Unexpected source version {version}; refusing to patch')

def once(s, old, new):
    if s.count(old) != 1: raise RuntimeError(f'Expected one anchor: {old[:100]!r}')
    return s.replace(old, new, 1)

def block(s, start, end, replacement):
    if s.count(start) != 1 or s.count(end) != 1: raise RuntimeError(f'Block drift: {start}')
    i = s.index(start); j = s.index(end, i)
    return s[:i] + replacement + s[j:]

pending = {}
p = app / 'OutlookReplyInsertion.swift'; s = p.read_text()
s = block(s, '    func start() {', '    private func scheduleTick()', '''    static func activateForReply(pid: pid_t) {
        guard let target = NSRunningApplication(processIdentifier: pid) else { return }
        if #available(macOS 14.0, *) {
            // Hiding the panel does not hand off app activation on modern macOS.
            if NSApp.isActive { NSApp.yieldActivation(to: target) }
            _ = target.activate(options: [])
        } else {
            _ = target.activate(options: [.activateIgnoringOtherApps])
        }
    }

    func start() {
        let app = AXUIElementCreateApplication(snapshot.pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        initialWindows = elements(app, "AXWindows")
        if let source = snapshot.windows.first {
            originalBodies = walk(source).filter { isBodyRole($0) }
        }
        beginWhenActive(attempt: 0)
    }

    private func beginWhenActive(attempt: Int) {
        guard !cancelled else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let decision = ReplyRecoveryRules.activation(
            outlookActive: frontmost == snapshot.pid,
            replyzenActive: frontmost == ProcessInfo.processInfo.processIdentifier,
            frontmostKnown: frontmost != nil, attempt: attempt)
        switch decision {
        case .ready:
            let accepted = outlook.openReplyComposer(replyAll: replyAll, from: snapshot)
            state = ReplyInsertionState(note: note, nativeOpenAccepted: accepted)
            scheduleTick()
            return
        case .request: Self.activateForReply(pid: snapshot.pid)
        case .wait: break
        case .abort: finish("R73-ACTIVATE"); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.beginWhenActive(attempt: attempt + 1)
        }
    }

''')
s = block(s, '    private func requestEditorFocus()', '    private func isDescendant(', '''    private func requestEditorFocus() {
        guard let editor, let targetWindow, isOutlookActive(),
              let window = focusedWindow(), CFEqual(window, targetWindow),
              !hasEditorFocus() else { return }
        focusAttempts += 1
        switch ReplyRecoveryRules.focusStep(attempt: focusAttempts) {
        case .accessibility:
            _ = AXUIElementSetAttributeValue(editor, "AXFocused" as CFString, kCFBooleanTrue)
            return
        case .press:
            // Restore the native focus fallback used before the Reply rewrite.
            _ = AXUIElementPerformAction(editor, "AXPress" as CFString)
            return
        case .subjectTab:
            // Navigate only. The following observation must prove body focus;
            // never paste merely because a Tab key was dispatched.
            if outlook.focusComposeSubjectField() { keyboard.sendTab() }
            return
        case .click: break
        }
        let rect = frame(editor).intersection(frame(targetWindow))
        guard !rect.isNull, rect.width > 20, rect.height > 20 else { return }
        let point = focusAttempts % 2 == 0
            ? CGPoint(x: rect.minX + min(24, rect.width / 2), y: rect.minY + min(16, rect.height / 2))
            : CGPoint(x: rect.midX, y: rect.midY)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit, isDescendant(hit, of: editor), let source = CGEventSource(stateID: .hidSystemState) else { return }
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func hasEditorFocus() -> Bool {
        guard isOutlookActive(), let editor, let targetWindow,
              let window = focusedWindow(), CFEqual(targetWindow, window),
              isDescendant(editor, of: targetWindow) else { return false }
        let app = AXUIElementCreateApplication(snapshot.pid)
        let candidates = [element(AXUIElementCreateSystemWide(), "AXFocusedUIElement"),
                          element(app, "AXFocusedUIElement")].compactMap { $0 }
        var reportsEditor = false, reportsOtherField = false
        for focused in candidates {
            // Membership of the exact draft/editor subtree is the identity check.
            // A renderer-backed AX child need not have the host application's PID.
            if isDescendant(focused, of: editor) {
                reportsEditor = true
            } else if !isDescendant(editor, of: focused) {
                let role = text(focused, "AXRole") ?? ""
                if ["AXTextField", "AXTextArea", "AXWebArea", "AXComboBox", "AXButton", "AXMenuItem"].contains(role) {
                    reportsOtherField = true
                }
            }
        }
        return ReplyRecoveryRules.hasFocus(active: true, sameWindow: true,
            reportsEditor: reportsEditor,
            editorMarkedFocused: bool(editor, "AXFocused") == true,
            reportsOtherField: reportsOtherField)
    }

''')
s = s.replace('R72-', 'R73-')
s = once(s, '        completion(errorCode)', '''        let diagnostic = errorCode == "R73-FOCUS"
            ? (isOutlookActive() ? "R73-EDITORFOCUS" : "R73-APPFOCUS") : errorCode
        completion(diagnostic)''')
pending[p] = s
# Existing state-machine behavior and no-duplicate-paste protections remain intact.
for relative in ['source-current/app/ReplyInsertionPolicy.swift', 'tests/ReplyInsertionPolicyTests.swift']:
    p = repo / relative; pending[p] = p.read_text().replace('R72-', 'R73-')

p = app / 'AppDelegate.swift'; s = p.read_text()
i = s.index('    private func insertReply()'); j = s.index('    private func insertForwardDraft()', i)
reply = once(s[i:j], '        outlook.activateOutlook(pid: snapshot.pid)',
             '        OutlookReplyInsertion.activateForReply(pid: snapshot.pid)')
s = s[:i] + reply + s[j:]
s = once(s, 'private func sendWithOptionalPreview(_ payload: ChatGPTTransferPayload, send:',
            'private func sendWithOptionalPreview(_ payload: ChatGPTTransferPayload, newMail: Bool = false, send:')
i = s.index('    private func sendWithOptionalPreview'); j = s.index('    private func generateReply()', i)
preview = once(s[i:j], 'MailPromptBuilder.make(payload: payload)', 'MailPromptBuilder.make(payload: payload, newMail: newMail)')
s = s[:i] + preview + s[j:]
i = s.index('    private func generateNewMail()'); j = s.index('    private func performNewMail', i)
new_mail = once(s[i:j], 'sendWithOptionalPreview(payload)', 'sendWithOptionalPreview(payload, newMail: true)')
s = s[:i] + new_mail + s[j:]; pending[p] = s

p = app / 'MailPromptBuilder.swift'; s = p.read_text()
s = once(s, 'static func make(payload: ChatGPTTransferPayload) -> MailWritingPrompt',
            'static func make(payload: ChatGPTTransferPayload, newMail: Bool = false) -> MailWritingPrompt')
s = once(s, '        return MailWritingPrompt(system: systemPrompt, user: userPrompt)', '''        let rules = newMail ? systemPrompt.replacingOccurrences(
            of: "- Return only the final text for the email editor.",
            with: "- Return a JSON object with subject, body and html. Always provide a short non-empty subject in the requested language based only on the user's instruction. Put only the message text in body, without the subject. Put the same body in email-safe HTML in html, or use an empty html string.") : systemPrompt
        return MailWritingPrompt(system: rules, user: userPrompt)''')
pending[p] = s

p = app / 'OpenAIClient.swift'; s = p.read_text()
i = s.index('    func generateNewMail('); j = s.index('    private var replyDraftResponseFormat', i)
new_mail = once(s[i:j], 'MailPromptBuilder.make(payload: payload)', 'MailPromptBuilder.make(payload: payload, newMail: true)')
new_mail = once(new_mail, 'Self.decodeNewMailDraft(text)', 'Self.decodeNewMailDraft(text, language: payload.language)')
s = s[:i] + new_mail + s[j:]
s = once(s, 'private static func decodeNewMailDraft(_ text: String) throws -> NewMailDraft',
            'private static func decodeNewMailDraft(_ text: String, language: String = "de") throws -> NewMailDraft')
old = '''            let draft = try JSONDecoder().decode(NewMailDraft.self, from: data)
            guard !draft.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw APIError(message: L10n.source("OpenAI hat keinen Betreff f\u00fcr die neue Mail geliefert."))
            }
'''
new = '''            struct WireDraft: Decodable {
                let subject: String?
                let body: String
                let html: String?
            }
            let draft = try JSONDecoder().decode(WireDraft.self, from: data)
'''
s = once(s, old, new)
i = s.index('    private static func decodeNewMailDraft'); j = s.index('    func summarizeThread', i)
decoder = once(s[i:j], '            return draft', '''            return NewMailDraft(
                subject: NewMailSubject.resolve(draft.subject, body: draft.body, language: language),
                body: draft.body, html: draft.html)''')
s = s[:i] + decoder + s[j:]
s = once(s, 'A short useful subject based only on the user\'s instruction.', 'A short, non-empty subject in the requested language, based only on the user\'s instruction.')
pending[p] = s

p = repo / 'tests/run-tests.sh'; s = p.read_text()
s = once(s, '"$SOURCE/app/OpenAIClient.swift"', '"$SOURCE/app/NewMailSubject.swift" "$SOURCE/app/OpenAIClient.swift"')
pending[p] = s
p = repo / 'tests/test_source_contracts.py'; s = p.read_text().replace('"1.72.0"', '"1.73.0"')
s = once(s, 'self.assertEqual(info["CFBundleVersion"], "73")', 'self.assertEqual(info["CFBundleVersion"], "74")')
s = once(s, 'self.assertIn("OpenAI hat keinen Betreff f\u00fcr die neue Mail geliefert.", client)', 'self.assertIn("NewMailSubject.resolve", client)')
s = once(s, 'client.count("MailPromptBuilder.make(payload: payload)")', 'client.count("MailPromptBuilder.make(payload: payload")')
compile(s, str(p), 'exec'); pending[p] = s
p = repo / 'tests/verify_update.py'; pending[p] = p.read_text().replace('1.72', '1.73').replace("manifest['build'] == 73", "manifest['build'] == 74")

p = repo / 'tests/ClientDecoderChecks.swift'; s = p.read_text()
anchor = '        let event = try decodeCalendarSuggestion('
assert s.count(anchor) == 1
extra = '''        // Exercise the actual decoder, not just a source-string contract.
        let retainedBody = "Hallo Max,\\n\\nBitte bestaetige den Liefertermin."
        let retainedHTML = "<p>Hallo Max,</p><p>Bitte bestaetige den Liefertermin.</p>"
        for subject in [NSNull(), "", " \\n\\t"] as [Any] {
            let data = try JSONSerialization.data(withJSONObject: ["subject": subject, "body": retainedBody, "html": retainedHTML])
            let result = try decodeNewMailDraft(String(decoding: data, as: UTF8.self))
            precondition(result.subject == "Bitte bestaetige den Liefertermin")
            precondition(result.body == retainedBody && result.html == retainedHTML)
        }
        let missingData = try JSONSerialization.data(withJSONObject: ["body": retainedBody, "html": retainedHTML])
        let recovered = try decodeNewMailDraft(String(decoding: missingData, as: UTF8.self))
        precondition(!recovered.subject.isEmpty && recovered.body == retainedBody)
'''
s = s.replace(anchor, extra + anchor, 1); pending[p] = s

notes = {
    'de': 'ReplyZen 1.73: Gezielte Korrektur der gemeldeten Fokus- und Betreff-Abbrueche. Antworten uebergibt die Aktivierung an Outlook, wartet auf die aktive App und nutzt wieder native Fokussierung sowie Betreff-Tab-Navigation mit Pruefung vor dem Einfuegen. Neue Mails fordern einen Betreff ausdruecklich an; fehlt er dennoch, bleibt der Mailtext erhalten und ein Betreff wird lokal daraus abgeleitet. Weiterleiten bleibt unveraendert. Automatisierte Tests ersetzen keinen Live-Test in der konkreten Outlook-Installation.',
    'en-US': 'ReplyZen 1.73: Targets the reported focus and empty-subject failures. Replies yield activation to Outlook, wait for it to become active, and restore native focus and subject-to-body navigation with verification before pasting. New Mail explicitly requests a subject and recovers an absent subject locally without discarding the body. Forward is unchanged. Automated tests do not replace validation in the actual Outlook installation.',
    'es': 'ReplyZen 1.73: Corrige los puntos de fallo de foco y asunto vacio. Responder cede la activacion a Outlook y restaura la navegacion al cuerpo con verificacion antes de pegar. Nuevo correo solicita el asunto expresamente y conserva el cuerpo si falta, derivando un asunto localmente. Reenviar no cambia. Falta la validacion en la instalacion real de Outlook.'
}
pending[root / 'Release-notes.txt'] = notes['de'] + '\n'
pending[root / 'Release-notes.localized.json'] = json.dumps(notes, ensure_ascii=False, indent=2) + '\n'
# Guard untouched transports against accidental broad replacements.
old_delegate = (app / 'AppDelegate.swift').read_text(); new_delegate = pending[app / 'AppDelegate.swift']
assert old_delegate[old_delegate.index('    private func insertForwardDraft()'):] == new_delegate[new_delegate.index('    private func insertForwardDraft()'):]
for path, content in pending.items(): path.write_text(content, encoding='utf-8')
info['CFBundleShortVersionString'] = '1.73.0'; info['CFBundleVersion'] = '74'
info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
print('Integrated 1.73 / build 74 focus handoff and non-destructive subject recovery')
