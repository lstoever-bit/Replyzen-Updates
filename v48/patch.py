from pathlib import Path
import sys

root = Path(sys.argv[1])


def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f"{label} not found")
    return text.replace(old, new, 1)

p = root / "app" / "OutlookToolbarButtonController.swift"
s = p.read_text()
s = must_replace(
    s,
    '''        effect.layer?.cornerRadius = 9\n        effect.layer?.masksToBounds = true\n''',
    '''        effect.layer?.cornerRadius = 9\n        effect.layer?.masksToBounds = true\n        // Keep the native translucent Outlook feel, but separate the Replyzen bar\n        // very slightly from Outlook's default toolbar gray.\n        effect.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.22).cgColor\n''',
    "subtle overlay background",
)
s = must_replace(
    s,
    '        let y = frame.maxY - size.height - 48\n',
    '        let y = frame.maxY - size.height - 38\n',
    "overlay position",
)
p.write_text(s)

p = root / "app" / "Info.plist"
s = p.read_text()
s = s.replace('<string>1.34.0</string>', '<string>1.35.0</string>', 1)
s = s.replace('<string>35</string>', '<string>36</string>', 1)
p.write_text(s)

p = root / "Build-CI.sh"
s = p.read_text()
s = s.replace('Replyzen-update-1.34.zip', 'Replyzen-update-1.35.zip')
s = s.replace(
    'Replyzen 1.34: New, Reply und Forward verwenden dieselbe Mail Form mit WYSIWYG, Mood, Compact, Sprache und Reminder. Forward wird jetzt wie Reply/New Mail mit OpenAI formuliert und danach als nativer Outlook Forward ohne Empfänger eingesetzt; Thread und Anhänge bleiben erhalten. Termin wurde aus der Replyzen Hauptnavigation entfernt und ist nur noch als Termin Button hinter Cancel im Outlook Overlay verfügbar.',
    'Replyzen 1.35: Das Outlook Overlay sitzt wieder ein kleines Stück höher, ohne den Suchschlitz zu überdecken, und hebt sich mit einem sehr dezenten eigenen Hintergrund vom Standardgrau ab. Enthält weiterhin die einheitliche Mail Form für New, Reply und Forward sowie Termin nur im Outlook Overlay hinter Cancel.'
)
p.write_text(s)
