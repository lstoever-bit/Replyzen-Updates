#!/usr/bin/env python3
"""Checked, idempotent wiring of shared 10.5 pt typography into the 1.43 app."""
from pathlib import Path
import hashlib
import plistlib
import sys

root = Path(sys.argv[1])
app = root / "app"
info = plistlib.loads((app / "Info.plist").read_bytes())
if info["CFBundleShortVersionString"] == "1.44.0":
    assert 'MailTypography.write' in (app / 'AppDelegate.swift').read_text()
    assert 'MailTypography.baseFont' in (app / 'RichTextMailEditor.swift').read_text()
    print('ReplyZen 1.44 typography already applied')
    raise SystemExit(0)
assert info["CFBundleShortVersionString"] == "1.43.0", 'Unexpected source version'

def read_checked(name, sha):
    data = (app / name).read_bytes()
    actual = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
    assert actual == sha, 'Source changed since review: ' + name
    return data.decode('utf-8')

s = read_checked('AppDelegate.swift', 'c9bb5b64b14d2e920ac252c9f4a5de2c1bec83eb')
start = s.index('    private func copyMailToPasteboard(plainText: String, html: String) {')
end = s.index('    private func copyToPasteboard(_ text: String)', start)
s = s[:start] + '''    private func copyMailToPasteboard(plainText: String, html: String) {
        MailTypography.write(plainText: plainText, html: html)
    }

''' + s[end:]
start = s.index('    private func insertQuickReply(')
end = s.index('    @objc private func menuReply()', start)
quick = s[start:end]
assert quick.count('copyToPasteboard(reply)') == 2
quick = quick.replace('copyToPasteboard(reply)', 'copyMailToPasteboard(plainText: reply, html: "")')
s = s[:start] + quick + s[end:]

editor = read_checked('RichTextMailEditor.swift', '62cece160defb5cd516f45e7ef0388e9f71f5af5')
assert editor.count('NSFont.systemFont(ofSize: 14)') >= 7
editor = editor.replace('NSFont.systemFont(ofSize: 14)', 'MailTypography.baseFont')
start = editor.index('            if !parent.html.isEmpty,')
end = editor.index('        func textDidChange(', start)
editor = editor[:start] + '''            textView.textStorage?.setAttributedString(
                MailTypography.attributedString(plainText: parent.plainText, html: parent.html)
            )
            textView.typingAttributes = [.font: MailTypography.baseFont]
        }

''' + editor[end:]
old = '''            parent.plainText = textView.string
            parent.html = Self.html(from: textView.attributedString())'''
new = '''            isApplyingExternalValue = true
            defer { isApplyingExternalValue = false }
            if let storage = textView.textStorage {
                MailTypography.normalizeFonts(in: storage)
            }
            textView.typingAttributes[.font] = MailTypography.font(
                preserving: textView.typingAttributes[.font] as? NSFont
            )
            parent.plainText = textView.string
            parent.html = Self.html(from: textView.attributedString())'''
assert editor.count(old) == 1
editor = editor.replace(old, new, 1)
info['CFBundleShortVersionString'] = '1.44.0'
info['CFBundleVersion'] = '45'
(app / 'AppDelegate.swift').write_text(s, encoding='utf-8')
(app / 'RichTextMailEditor.swift').write_text(editor, encoding='utf-8')
(app / 'Info.plist').write_bytes(plistlib.dumps(info, sort_keys=False))
print('ReplyZen 1.44: Calibri Light 10.5 pt, including plain-text and quick-reply paths')
