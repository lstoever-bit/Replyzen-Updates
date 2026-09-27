#!/usr/bin/env python3
"""Apply Reply-only editor compatibility fixes, refusing source drift."""
from pathlib import Path
import json
import plistlib
import sys

root = Path(sys.argv[1])
repo = root.parent
app = root / 'app'
info_path = app / 'Info.plist'
info = plistlib.loads(info_path.read_bytes())
version = (info.get('CFBundleShortVersionString'), str(info.get('CFBundleVersion')))
if version not in [('1.71.0', '72'), ('1.72.0', '73')]:
    raise SystemExit(f'Unexpected source {version}; refusing to modify')

def once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f'Expected one exact anchor: {old[:100]!r}')
    return text.replace(old, new, 1)

adapter_path = app / 'OutlookReplyInsertion.swift'
s = adapter_path.read_text(encoding='utf-8')
if version == ('1.72.0', '73'):
    for token in ['pasteThroughOutlook()', 'ReplyEditorSupport.readText(', 'ReplyEditorSupport.nodes(', 'AXSelectedText', 'postToPid']:
        assert token in s, token
    assert (app / 'ReplyEditorSupport.swift').is_file()
    print('ReplyZen 1.72 integration already applied')
    raise SystemExit(0)

s = once(s, '            keyboard.sendCommandV()\n', '            pasteThroughOutlook()\n')
s = once(s, 'let editable = bool(candidate, "AXEditable") == true || settable(candidate, "AXValue")',
'''let editable = bool(candidate, "AXEditable") == true || settable(candidate, "AXValue")
                        || settable(candidate, "AXSelectedText")''')
# A writable selected TEXT is an editing operation; a writable selection RANGE is not.
start = s.index('    private func hasEditorFocus() -> Bool {')
end = s.index('    private func isDescendant(', start)
s = s[:start] + '''    private func hasEditorFocus() -> Bool {
        guard isOutlookActive(), let editor, let targetWindow,
              let window = focusedWindow(), CFEqual(targetWindow, window) else { return false }
        let app = AXUIElementCreateApplication(snapshot.pid)
        let candidates = [element(app, "AXFocusedUIElement"),
                          element(AXUIElementCreateSystemWide(), "AXFocusedUIElement")]
        return candidates.compactMap { $0 }.contains { focused in
            var pid: pid_t = 0
            return AXUIElementGetPid(focused, &pid) == .success && pid == snapshot.pid
                && isDescendant(focused, of: editor)
        }
    }

''' + s[end:]
start = s.index('    private func bodyText(_ node: AXUIElement) -> String? {')
end = s.index('    private func isOutlookActive()', start)
s = s[:start] + '''    private func bodyText(_ node: AXUIElement) -> String? {
        ReplyEditorSupport.readText(
            value: { self.text(node, "AXValue") },
            characterCount: { (self.raw(node, "AXNumberOfCharacters") as? NSNumber)?.intValue },
            rangeText: { range in
                var cfRange = CFRange(location: range.location, length: range.length)
                guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
                for attribute in ["AXStringForRange", "AXAttributedStringForRange"] {
                    var result: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(node, attribute as CFString, parameter, &result) == .success {
                        if let plain = result as? String { return plain }
                        if let rich = result as? NSAttributedString { return rich.string }
                    }
                }
                return nil
            },
            descendants: { self.descendantBodyText(node) }
        )
    }

    private func descendantBodyText(_ root: AXUIElement) -> String? {
        // Prune a readable text subtree so its value is not counted again in children.
        func leafText(_ node: AXUIElement) -> String? {
            guard !CFEqual(node, root), self.isBodyRole(node) || self.text(node, "AXRole") == "AXStaticText" else { return nil }
            if let value = self.text(node, "AXValue"), !value.isEmpty { return value }
            if self.text(node, "AXRole") == "AXStaticText", let title = self.text(node, "AXTitle"), !title.isEmpty { return title }
            return nil
        }
        guard let nodes = ReplyEditorSupport.nodes(root: root,
            children: { leafText($0) == nil ? self.elements($0, "AXChildren") : [] },
            hash: { UInt(CFHash($0)) }, equal: { CFEqual($0, $1) }) else { return nil }
        let pieces = nodes.compactMap { leafText($0) }
        return pieces.isEmpty ? nil : pieces.joined(separator: "\\n")
    }

    private func pasteThroughOutlook() {
        // Prefer Outlook's own standard Paste action over a simulated shortcut.
        // After ANY native dispatch result, verify instead of issuing another paste.
        guard isOutlookActive(), hasEditorFocus() else { finish("R72-FOCUS"); return }
        let app = AXUIElementCreateApplication(snapshot.pid)
        if let menuBar = element(app, "AXMenuBar"), let paste = walk(menuBar).first(where: { item in
            guard self.text(item, "AXRole") == "AXMenuItem", self.bool(item, "AXEnabled") == true else { return false }
            return ReplyEditorSupport.isStandardPaste(
                title: self.text(item, "AXTitle") ?? "",
                key: self.text(item, "AXMenuItemCmdChar"),
                modifiers: (self.raw(item, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue)
        }) {
            guard isOutlookActive(), hasEditorFocus() else { finish("R72-FOCUS"); return }
            _ = AXUIElementPerformAction(paste, "AXPress" as CFString)
            return
        }
        // Some Outlook builds do not expose their menu. In that case send one
        // balanced shortcut directly to Outlook, not the global event stream.
        guard isOutlookActive(), hasEditorFocus(),
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            finish("R72-PASTE"); return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        let pid = snapshot.pid
        down.postToPid(pid)
        // Always balance the key-down, even if the user cancels in this interval.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { up.postToPid(pid) }
    }

''' + s[end:]
start = s.index('    private func walk(_ root: AXUIElement) -> [AXUIElement] {')
end = s.index('    private func frame(', start)
s = s[:start] + '''    private func walk(_ root: AXUIElement) -> [AXUIElement] {
        ReplyEditorSupport.nodes(root: root,
            children: { self.elements($0, "AXChildren") },
            hash: { UInt(CFHash($0)) }, equal: { CFEqual($0, $1) }) ?? []
    }
''' + s[end:]
s = s.replace('return value as! AXUIElement', 'return (value as! AXUIElement)').replace('R71-', 'R72-')

# Calculate every replacement before writing anything.
updates = {adapter_path: s}
p = app / 'ReplyInsertionPolicy.swift'
updates[p] = p.read_text().replace('R71-', 'R72-')
p = repo / 'tests/ReplyInsertionPolicyTests.swift'
updates[p] = p.read_text().replace('R71-', 'R72-')
p = repo / 'tests/test_source_contracts.py'
s = p.read_text()
s = once(s, 'self.assertEqual(info["CFBundleShortVersionString"], "1.71.0")', 'self.assertEqual(info["CFBundleShortVersionString"], "1.72.0")')
s = once(s, 'self.assertEqual(info["CFBundleVersion"], "72")', 'self.assertEqual(info["CFBundleVersion"], "73")')
compile(s, str(p), 'exec')
updates[p] = s
p = repo / 'tests/verify_update.py'
s = p.read_text().replace('1.71', '1.72')
s = once(s, "manifest['build'] == 72", "manifest['build'] == 73")
compile(s, str(p), 'exec')
updates[p] = s
notes = {
 'de': 'ReplyZen 1.72: Erweitert beim Antworten das Auslesen von HTML-Editoren um native Textbereich-Schnittstellen und korrigiert die Erkennung unterschiedlicher Bedienungshilfe-Elemente. Verwendet bevorzugt Outlooks eigenen Einfügen-Befehl; falls nicht verfügbar, wird ein einzelner Tastaturbefehl direkt an Outlook gesendet. Fokus- und Ergebnisprüfung bleiben aktiv. Die konkrete Fehlerursache ohne Diagnosecode ist noch nicht bestätigt; Live-Test in Outlook steht aus.',
 'en-US': 'ReplyZen 1.72: Adds native text-range reads for HTML reply editors and fixes collision handling when identifying Accessibility elements. Prefers Outlook native Paste; otherwise dispatches a single shortcut directly to Outlook. Focus and result verification remain enabled. The reported failure is not yet attributed without its diagnostic code; live Outlook validation remains outstanding.',
 'es': 'ReplyZen 1.72: Añade lectura nativa por rangos en editores HTML y corrige la identificación de elementos de Accesibilidad. Prioriza Pegar de Outlook y, si no está disponible, envía un solo atajo directamente a Outlook. Mantiene la comprobación del foco y del resultado. Falta confirmar el fallo comunicado con su código y una prueba real en Outlook.'
}
updates[root / 'Release-notes.txt'] = notes['de'] + '\n'
updates[root / 'Release-notes.localized.json'] = json.dumps(notes, ensure_ascii=False, indent=2) + '\n'
# New Mail, Forward and their shared helpers are outside this migration.
info['CFBundleShortVersionString'] = '1.72.0'
info['CFBundleVersion'] = '73'
for path, content in updates.items():
    path.write_text(content, encoding='utf-8')
info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
print('Applied ReplyZen 1.72 / build 73 editor compatibility fixes')
