#!/usr/bin/env python3
"""Diagnostic branch only. Preserve insertion decisions and the regular channel."""
from pathlib import Path
import hashlib
import json
import plistlib
import sys

root = Path(sys.argv[1]); app = root / 'app'; repo = root.parent
originals = {p: p.read_bytes() for p in app.rglob('*') if p.is_file()}
info_file = app / 'Info.plist'
info = plistlib.loads(info_file.read_bytes())
assert (info['CFBundleShortVersionString'], str(info['CFBundleVersion'])) == ('1.75.0', '76')
p = app / 'OutlookReplyInsertion.swift'
s = p.read_text()
original = s
changes = [(
    '        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier\n',
    '        let frontmostApplication = NSWorkspace.shared.frontmostApplication\n'
    '        let frontmostPID = frontmostApplication?.processIdentifier\n'
), (
    '        case .abort(let code):\n            finish(code)\n            return false\n',
    '        case .abort(let code):\n'
    '            // Record the same foreground sample that caused this decision,\n'
    '            // BEFORE completion displays ReplyZen and changes app focus.\n'
    '            let details = ReplyFocusDiagnostic.capture(\n'
    '                observed: frontmostApplication, expectedPID: snapshot.pid,\n'
    '                sourceWindow: snapshot.windows.first, targetWindow: targetWindow,\n'
    '                pasteRequested: pasted, ownInteractiveWindow: ownInteractiveWindow)\n'
    '            finish(code, details: details)\n'
    '            return false\n'
), (
    '    private func finish(_ errorCode: String?) {\n',
    '    private func finish(_ errorCode: String?, details: String? = nil) {\n'
), (
    '        completion(diagnostic == "R74-WINDOW" ? (windowFailure ?? diagnostic) : diagnostic)\n',
    '        if let diagnostic, let details {\n'
    '            let code = diagnostic == "R74-WINDOW" ? (windowFailure ?? diagnostic) : diagnostic\n'
    '            completion(code + "\\n" + details)\n'
    '            return\n'
    '        }\n'
    '        completion(diagnostic == "R74-WINDOW" ? (windowFailure ?? diagnostic) : diagnostic)\n'
)]
for old, new in changes:
    assert s.count(old) == 1, f'Unexpected integration anchor: {old!r}'
    s = s.replace(old, new, 1)
reverse = s
for old, new in reversed(changes):
    assert reverse.count(new) == 1
    reverse = reverse.replace(new, old, 1)
assert reverse == original
p.write_text(s)
info['CFBundleShortVersionString'] = '1.75.1'
info['CFBundleVersion'] = '77'
info_file.write_bytes(plistlib.dumps(info, sort_keys=False))

def exact(path, replacements):
    text = path.read_text()
    for old, new in replacements:
        assert text.count(old) == 1, (path, old)
        text = text.replace(old, new, 1)
    compile(text, str(path), 'exec')
    path.write_text(text)

exact(repo / 'tests/test_source_contracts.py', [
    ('self.assertEqual(info["CFBundleShortVersionString"], "1.75.0")', 'self.assertEqual(info["CFBundleShortVersionString"], "1.75.1")'),
    ('self.assertEqual(info["CFBundleVersion"], "76")', 'self.assertEqual(info["CFBundleVersion"], "77")')])
exact(repo / 'tests/verify_update.py', [
    ("manifest['version'] == '1.75.0' and manifest['build'] == 76", "manifest['version'] == '1.75.1' and manifest['build'] == 77"),
    ("'Replyzen-update-1.75.zip'", "'Replyzen-update-1.75.1.zip'"),
    ('PASS: 1.75 version/build', 'PASS: 1.75.1 diagnostic version/build')])
notes = {
    'de': 'Diagnoseversion 1.75.1: Zeigt bei einem Fokus-Abbruch die tatsaechlich erkannten Anwendungen, Prozessnummern und die Beziehung zum Zielfenster. Keine Aenderung des Einfuegeablaufs oder der Schutzpruefungen. Keine Mailtexte, Betreffzeilen, Fenstertitel oder Zwischenablageninhalte in der Diagnose. Kein automatischer Upload. Kein Bugfix-Versprechen.',
    'en-US': 'Diagnostic build 1.75.1: Shows application identity, process IDs and target-window relationship at a foreground abort. No change to insertion decisions or safety checks. Excludes email content, subjects, window titles and clipboard data. No automatic upload. Not a verified bug fix.',
    'es': 'Version de diagnostico 1.75.1: Muestra aplicaciones, procesos y relacion con la ventana al fallar el foco. No cambia el pegado ni sus comprobaciones. No incluye correos, asuntos, titulos ni portapapeles. Sin envio automatico. No es una solucion confirmada.'
}
(root / 'Release-notes.txt').write_text(notes['de']+'\n')
(root / 'Release-notes.localized.json').write_text(json.dumps(notes, ensure_ascii=False, indent=2)+'\n')
for path, data in originals.items():
    if path not in {p, info_file}:
        assert path.read_bytes() == data, f'Unrelated app source changed: {path}'
helper = (app / 'ReplyFocusDiagnostic.swift').read_text()
for forbidden in ['AXUIElementPerformAction(', 'AXUIElementSetAttributeValue(', 'NSPasteboard', 'FileManager', 'URLSession', 'activate(', 'AXTitle', 'AXValue', 'AXDescription']:
    assert forbidden not in helper, f'Unexpected sampler capability: {forbidden}'
assert s.index('case .abort(let code):') < s.index('ReplyFocusDiagnostic.capture(')
assert 'observed: frontmostApplication' in s
print('PASS: failure-only sampling; original insertion decisions retained; all unrelated app files unchanged')
