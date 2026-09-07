from pathlib import Path

root = Path(__import__('sys').argv[1])

# Floating panel: materially larger default and minimum size.
p = root / 'app' / 'FloatingPanelController.swift'
s = p.read_text()
s = s.replace('contentRect: NSRect(x: 0, y: 0, width: 720, height: 650)',
              'contentRect: NSRect(x: 0, y: 0, width: 840, height: 760)')
s = s.replace('panel.minSize = NSSize(width: 620, height: 540)',
              'panel.minSize = NSSize(width: 700, height: 620)')
s = s.replace('frame.size.width = max(620, visible.width - 40)',
              'frame.size.width = max(700, visible.width - 28)')
s = s.replace('frame.size.height = max(540, visible.height - 40)',
              'frame.size.height = max(620, visible.height - 28)')
p.write_text(s)

# Calendar preview must never clip: make the whole form vertically scrollable as a fallback.
p = root / 'app' / 'OverlayView.swift'
s = p.read_text()
old = '''        case .calendarPreview:\n            calendarPreviewView\n'''
new = '''        case .calendarPreview:\n            ScrollView {\n                calendarPreviewView\n                    .frame(maxWidth: .infinity, alignment: .leading)\n            }\n'''
if old not in s:
    raise SystemExit('calendarPreview switch block not found')
s = s.replace(old, new, 1)
p.write_text(s)

# Version bump.
p = root / 'app' / 'Info.plist'
s = p.read_text()
s = s.replace('<string>1.7.0</string>', '<string>1.8.0</string>', 1)
s = s.replace('<string>8</string>', '<string>9</string>', 1)
p.write_text(s)

# Update notes.
p = root / 'Build-CI.sh'
s = p.read_text()
s = s.replace('Replyzen 1.7: größeres, frei skalierbares Fenster; leeres Einstellungsfenster entfernt.',
              'Replyzen 1.8: deutlich größeres Terminfenster; Terminansicht scrollt bei kleinen Displays, damit nichts abgeschnitten wird.')
p.write_text(s)
