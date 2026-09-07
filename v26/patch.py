from pathlib import Path
import sys

root = Path(sys.argv[1])

# Outlook pseudo-toolbar button: use the real Replyzen name and bundled Replyzen logo.
p = root / 'app' / 'OutlookToolbarButtonController.swift'
s = p.read_text()

s = s.replace('let size = NSSize(width: 66, height: 32)', 'let size = NSSize(width: 112, height: 34)', 1)

old = '''        button = NSButton(frame: effect.bounds.insetBy(dx: 4, dy: 3))
        button.title = "✨ AI"
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12.5, weight: .semibold)
        button.target = nil
        button.action = nil
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        effect.addSubview(button)
'''
new = '''        button = NSButton(frame: effect.bounds.insetBy(dx: 4, dy: 3))
        button.title = "Replyzen"
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12.5, weight: .semibold)
        button.alignment = .center
        button.target = nil
        button.action = nil
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.toolTip = "Replyzen"

        if let logoURL = Bundle.main.url(forResource: "ReplyzenLogo", withExtension: "png"),
           let logo = NSImage(contentsOf: logoURL) {
            logo.size = NSSize(width: 18, height: 18)
            button.image = logo
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
        }

        effect.addSubview(button)
'''
if old not in s:
    raise SystemExit('toolbar button block not found')
s = s.replace(old, new, 1)
p.write_text(s)

# Version bump.
p = root / 'app' / 'Info.plist'
s = p.read_text()
s = s.replace('<string>1.15.0</string>', '<string>1.16.0</string>', 1)
s = s.replace('<string>16</string>', '<string>17</string>', 1)
p.write_text(s)

# Update package and release notes.
p = root / 'Build-CI.sh'
s = p.read_text()
s = s.replace('Replyzen-update-1.15.zip', 'Replyzen-update-1.16.zip')
s = s.replace('Replyzen 1.15: Termintitel und -text folgen strikt der gewählten Sprache; New Mail hat Mood plus Compact statt Commands; native Dialoge verwenden Replyzen-Name und Replyzen-Logo.',
              'Replyzen 1.16: Der Outlook-Button zeigt jetzt den Namen Replyzen und das echte Replyzen-Logo statt ✨ AI.')
p.write_text(s)
