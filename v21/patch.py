from pathlib import Path

root = Path(__import__('sys').argv[1])

# Replace window controller with adaptive stage- and screen-aware sizing.
(root / 'app' / 'FloatingPanelController.swift').write_text(
    Path('v21/FloatingPanelController.swift').read_text()
)

# Make the main interaction screens scroll as a safety fallback on small displays.
p = root / 'app' / 'OverlayView.swift'
s = p.read_text()
old = '''        case .instruction:\n            instructionView\n'''
new = '''        case .instruction:\n            ScrollView {\n                instructionView\n                    .frame(maxWidth: .infinity, alignment: .leading)\n                    .padding(.bottom, 6)\n            }\n'''
if old not in s:
    raise SystemExit('instruction switch block not found')
s = s.replace(old, new, 1)

old = '''        case .preview:\n            previewView\n'''
new = '''        case .preview:\n            ScrollView {\n                previewView\n                    .frame(maxWidth: .infinity, alignment: .leading)\n                    .padding(.bottom, 6)\n            }\n'''
if old not in s:
    raise SystemExit('preview switch block not found')
s = s.replace(old, new, 1)
p.write_text(s)

# Version bump.
p = root / 'app' / 'Info.plist'
s = p.read_text()
s = s.replace('<string>1.10.0</string>', '<string>1.11.0</string>', 1)
s = s.replace('<string>11</string>', '<string>12</string>', 1)
p.write_text(s)

# Version-specific update package + notes.
p = root / 'Build-CI.sh'
s = p.read_text()
s = s.replace('Replyzen-update-1.10.zip', 'Replyzen-update-1.11.zip')
s = s.replace(
    'Replyzen 1.10: Update-Cache behoben; Versionsprüfung und Download nutzen Cache-Busting, plus versionsspezifisches Update-Paket.',
    'Replyzen 1.11: Fenstergröße passt sich automatisch an Inhalt, Modus und verfügbare Bildschirmfläche an; Scroll-Fallback verhindert abgeschnittene Buttons.'
)
p.write_text(s)
