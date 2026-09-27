#!/usr/bin/env python3
"""Correct premature Reply window binding only; abort on unexpected source drift."""
from pathlib import Path
import hashlib
import json
import plistlib
import sys


def once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError('Expected one exact integration anchor: ' + repr(old[:110]))
    return text.replace(old, new, 1)


def update_state(text):
    text = text.replace('R73-', 'R74-')
    text = once(text, '        var targetChanged = false\n',
        '        var targetChanged = false\n        var windowPending = false\n        var editorRebound = false\n')
    return once(text, '        switch phase {\n', '''        if observation.windowPending {
            if phase == .verifying && phaseTicks > 25 { return fail("R74-VERIFY") }
            if phase != .verifying { phaseTicks = max(0, phaseTicks - 1) }
            return .wait
        }
        if observation.editorRebound && phase != .verifying {
            phase = .opening
            phaseTicks = 0
            before = nil
            confirmations = 0
        }
        switch phase {
''')


def main():
    root = Path(sys.argv[1])
    app = root / 'app'
    repo = root.parent
    info_path = app / 'Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    version = (info.get('CFBundleShortVersionString'), str(info.get('CFBundleVersion')))
    if version == ('1.74.0', '75'):
        assert 'windowTracker.lockForPaste' in (app / 'OutlookReplyInsertion.swift').read_text()
        assert 'windowPending' in (app / 'ReplyInsertionPolicy.swift').read_text()
        print('ReplyZen 1.74 window binding already integrated')
        return
    if version != ('1.73.0', '74'):
        raise RuntimeError(f'Unexpected source version {version}; refusing migration')

    protected = ['AppDelegate.swift', 'OpenAIClient.swift', 'MailPromptBuilder.swift',
                 'NewMailSubject.swift', 'OutlookAccessibility.swift', 'KeyboardController.swift',
                 'ReplyRecoveryRules.swift', 'ReplyEditorSupport.swift']
    fingerprints = {name: hashlib.sha256((app / name).read_bytes()).hexdigest() for name in protected}
    path = app / 'OutlookReplyInsertion.swift'
    text = path.read_text()
    text = once(text, '    private var targetWindow: AXUIElement?\n', '''    private var targetWindow: AXUIElement?
    private var windowFailure: String?
    private var windowTracker = ReplyWindowTracker<AXUIElement, AXUIElement>(
        sameWindow: { CFEqual($0, $1) }, sameEditor: { CFEqual($0, $1) })
''')
    old_fallback = '''            guard let focused = focusedWindow(), let source = snapshot.windows.first,
                  CFEqual(focused, source) else { finish("R73-WINDOW"); return }
            if replyAll { keyboard.sendCommandShiftR() } else { keyboard.sendCommandR() }
'''
    text = once(text, old_fallback, '''            // Focus may move after the observation. Do not dispatch into that
            // other window or fail immediately; the next observation resolves it.
            if let focused = focusedWindow(), let source = snapshot.windows.first,
               CFEqual(focused, source), bool(focused, "AXModal") != true {
                if replyAll { keyboard.sendCommandShiftR() } else { keyboard.sendCommandR() }
            }
''')
    text = once(text, '            pasted = true\n', '''            guard let window = focusedWindow(), let editor,
                  windowTracker.lockForPaste(window: window, editor: editor) else {
                finish("R74-WINDOW-WRITE"); return
            }
            pasted = true
''')
    start = text.index('    private func observe() -> ReplyInsertionState.Observation {')
    end = text.index('    private func resolveEditor(', start)
    old_observe = text[start:end]
    assert 'if targetWindow == nil { targetWindow = window }' in old_observe
    text = text[:start] + '''    private func observe() -> ReplyInsertionState.Observation {
        var result = ReplyInsertionState.Observation()
        result.active = isOutlookActive()
        guard result.active else { return result }
        guard let window = focusedWindow() else {
            _ = windowTracker.observe(window: nil, editor: nil, isSource: false,
                existedBefore: false, hasSend: false, modal: false)
            result.windowPending = true
            return result
        }
        let isSource = snapshot.windows.first.map { CFEqual($0, window) } ?? false
        let existed = initialWindows.contains { CFEqual($0, window) }
        let modal = bool(window, "AXModal") == true
        let sameTarget = targetWindow.map { CFEqual($0, window) } ?? false
        let cachedIsValid = sameTarget && !modal
            && editor.map { isBodyRole($0) && isDescendant($0, of: window) } == true
            && sendControl.map { isDescendant($0, of: window) } == true
        let controls: [AXUIElement]
        let resolvedEditor: AXUIElement?
        if cachedIsValid, let sendControl {
            controls = [sendControl]
            resolvedEditor = editor
        } else {
            controls = walk(window).filter { node in
                let role = text(node, "AXRole") ?? ""
                guard role == "AXButton" || role == "AXMenuButton" else { return false }
                return ["AXTitle", "AXDescription", "AXHelp"].compactMap { text(node, $0) }
                    .contains(where: ReplyInsertionPolicy.isSendControl)
            }
            resolvedEditor = controls.isEmpty ? nil : resolveEditor(sendControls: controls, window: window)
        }
        let decision = windowTracker.observe(window: window, editor: resolvedEditor,
            isSource: isSource, existedBefore: existed, hasSend: !controls.isEmpty, modal: modal)
        switch decision {
        case .wait:
            result.windowPending = true
            return result
        case .openingSource:
            // Preserve the one-time native-open keyboard fallback on the SOURCE
            // only. Waiting for another window must never dispatch this shortcut.
            return result
        case .reject(let code):
            windowFailure = code
            result.targetChanged = true
            return result
        case .ready(let rebound):
            // Only now bind a complete, stable composer. A legitimate pre-paste
            // source-to-detached transition restarts focus/caret preparation.
            targetWindow = window
            editor = resolvedEditor
            sendControl = controls.first
            if rebound { focusAttempts = 0 }
            result.editorRebound = rebound
        }
        result.composer = true
        result.editor = editor != nil
        result.focused = hasEditorFocus()
        if let editor {
            result.text = bodyText(editor)
            if let rawRange = raw(editor, "AXSelectedTextRange"), CFGetTypeID(rawRange) == AXValueGetTypeID() {
                let value = rawRange as! AXValue
                var range = CFRange()
                if AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range) {
                    result.caretAtStart = range.location == 0 && range.length == 0
                }
            }
        }
        return result
    }

''' + text[end:]
    text = text.replace('R73-', 'R74-')
    text = once(text, '        completion(diagnostic)\n',
        '        completion(diagnostic == "R74-WINDOW" ? (windowFailure ?? diagnostic) : diagnostic)\n')
    path.write_text(text)
    path = app / 'ReplyInsertionPolicy.swift'
    path.write_text(update_state(path.read_text()))

    p = repo / 'tests/ReplyInsertionPolicyTests.swift'
    p.write_text(p.read_text().replace('R73-', 'R74-'))
    p = repo / 'tests/test_source_contracts.py'
    text = once(p.read_text(), '"1.73.0"', '"1.74.0"')
    text = once(text, 'self.assertEqual(info["CFBundleVersion"], "74")',
                        'self.assertEqual(info["CFBundleVersion"], "75")')
    compile(text, str(p), 'exec')
    p.write_text(text)
    p = repo / 'tests/verify_update.py'
    text = p.read_text().replace('1.73', '1.74')
    text = once(text, "manifest['build'] == 74", "manifest['build'] == 75")
    p.write_text(text)

    notes = {
        'de': 'ReplyZen 1.74: Korrigiert die vorzeitige Bindung an das Quellfenster beim Antworten. Ein Senden-Knopf allein legt das Zielfenster nicht mehr fest. Ein stabiler Antworteditor wird abgewartet; der Wechsel vom Quellfenster in einen neuen Antwortentwurf ist vor dem Einfuegen moeglich. Nach dem Einfuegen bleibt das Ziel gesperrt, ohne automatische Doppeleinfuegung. Betreff-Erzeugung und Weiterleitung bleiben unveraendert. Ablauf-Tests sind kein Live-Test in Outlook.',
        'en-US': 'ReplyZen 1.74: Fixes premature binding to the source window during Reply. A Send control alone no longer selects the target. Waits for a stable reply editor and permits the source-to-detached transition before pasting. After pasting the target stays locked, with no automatic duplicate paste. Subject generation and Forward are unchanged. Sequence tests are not live Outlook validation.',
        'es': 'ReplyZen 1.74: Corrige la seleccion prematura de la ventana de origen al responder. Espera un editor estable y permite pasar a un nuevo borrador antes de pegar. Despues de pegar mantiene el destino bloqueado, sin duplicar el texto. No cambia los asuntos ni Reenviar. Las pruebas de secuencia no son pruebas reales de Outlook.'
    }
    (root / 'Release-notes.txt').write_text(notes['de'] + '\n')
    (root / 'Release-notes.localized.json').write_text(json.dumps(notes, ensure_ascii=False, indent=2) + '\n')
    info['CFBundleShortVersionString'] = '1.74.0'
    info['CFBundleVersion'] = '75'
    info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
    for name, digest in fingerprints.items():
        assert hashlib.sha256((app / name).read_bytes()).hexdigest() == digest, name
    print('Integrated ReplyZen 1.74 / build 75; eight protected source files byte-for-byte unchanged')


if __name__ == '__main__':
    main()
