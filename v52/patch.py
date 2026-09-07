from pathlib import Path
import sys

root = Path(sys.argv[1])

# Outlook overlay: one contextual separator, faster tooltip, stronger visual separation.
p = root / "app" / "OutlookToolbarButtonController.swift"
s = p.read_text()
s = s.replace('DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)',
              'DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: item)')
s = s.replace('let size = NSSize(width: 322, height: 34)',
              'let size = NSSize(width: 302, height: 34)')
old_effect = '''        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
        effect.layer?.masksToBounds = true
        // Keep the subtle Replyzen tint requested for the Outlook overlay.
        effect.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.22).cgColor
'''
new_effect = '''        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
        effect.layer?.masksToBounds = true
        // Deliberately a little stronger than Outlook's toolbar gray so Replyzen
        // reads as one compact control while still feeling native on macOS.
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let overlayTint = isDark
            ? NSColor(calibratedWhite: 0.16, alpha: 0.78)
            : NSColor(calibratedWhite: 0.84, alpha: 0.82)
        effect.layer?.backgroundColor = overlayTint.cgColor
        effect.layer?.borderWidth = 0.6
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
'''
if old_effect not in s:
    raise SystemExit("overlay effect block not found")
s = s.replace(old_effect, new_effect, 1)
s = s.replace('calendarButton = makeButton(symbol: "calendar.badge.plus", x: 228, tooltip: "Calendar")',
              'calendarButton = makeButton(symbol: "calendar.badge.plus", x: 218, tooltip: "Calendar")')
s = s.replace('paymentButton = makeButton(symbol: "banknote", x: 278, tooltip: "Payment")',
              'paymentButton = makeButton(symbol: "banknote", x: 258, tooltip: "Payment")')
s = s.replace('''        effect.addSubview(makePipe(x: 166))
        effect.addSubview(cancelButton)
        effect.addSubview(makePipe(x: 216))
        effect.addSubview(calendarButton)
        effect.addSubview(makePipe(x: 266))
        effect.addSubview(paymentButton)
''', '''        effect.addSubview(makePipe(x: 166))
        effect.addSubview(cancelButton)
        effect.addSubview(calendarButton)
        effect.addSubview(paymentButton)
''', 1)
p.write_text(s)

# Main mail form: larger editor, tighter vertical rhythm, no large elastic gray gap.
p = root / "app" / "OverlayView.swift"
s = p.read_text()
s = s.replace('''    private var instructionView: some View {
        VStack(alignment: .leading, spacing: 14) {
''', '''    private var instructionView: some View {
        VStack(alignment: .leading, spacing: 10) {
''', 1)
s = s.replace('''            HStack(spacing: 10) {
                replyzenLogo(size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Replyzen")
                        .font(.title2.bold())
                    Text("Mail AI")
                        .font(.caption)
''', '''            HStack(spacing: 8) {
                replyzenLogo(size: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Replyzen")
                        .font(.headline)
                    Text("Mail AI")
                        .font(.caption2)
''', 1)
s = s.replace('''                    height: 320,
''', '''                    height: 390,
''', 1)
s = s.replace('''            Spacer(minLength: 12)

            Divider()
''', '''            Divider()
                .padding(.top, 2)
''', 1)
p.write_text(s)

# Make the mail composer window fit its content instead of leaving a large gray lower area.
p = root / "app" / "FloatingPanelController.swift"
s = p.read_text()
s = s.replace('return NSSize(width: 900, height: 800)',
              'return NSSize(width: 900, height: 710)', 1)
p.write_text(s)

# Version metadata.
p = root / "app" / "Info.plist"
s = p.read_text()
s = s.replace('<string>1.38.0</string>', '<string>1.39.0</string>', 1)
s = s.replace('<string>39</string>', '<string>40</string>', 1)
p.write_text(s)

p = root / "Build-CI.sh"
s = p.read_text()
s = s.replace('Replyzen-update-1.38.zip', 'Replyzen-update-1.39.zip')
s = s.replace(
    'Replyzen 1.38: Das Outlook Overlay ist kompakt und zeigt nur noch Symbole. Die englischen Bezeichnungen erscheinen nach 1,5 Sekunden als Tooltip. Cancel, Calendar und Payment sind mit Pipes getrennt; der dezente Overlay Hintergrund bleibt erhalten. Command+A markiert jetzt im WYSIWYG Editor zuverlässig den gesamten Text.',
    'Replyzen 1.39: Im Outlook Overlay trennt nur noch ein Pipe Forward von den kontextuellen Aktionen Cancel, Calendar und Payment. Tooltips erscheinen nach 0,75 Sekunden und der Overlay Hintergrund hebt sich deutlicher von Outlook ab. Die Mail Form ist deutlich kompakter, das WYSIWYG Textfeld größer und die große graue Leerfläche entfernt.'
)
p.write_text(s)
