from pathlib import Path
import sys

root = Path(sys.argv[1])


def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f"{label} not found")
    return text.replace(old, new, 1)

# AppState: add reminder controls for the unified Mail form.
p = root / "app" / "AppState.swift"
s = p.read_text()
s = must_replace(
    s,
    '    @Published var newMailCompact: Bool = false\n    @Published var newMailSubject: String = ""\n',
    '    @Published var newMailCompact: Bool = false\n    @Published var reminderEnabled: Bool = false\n    @Published var reminderDay: String = "wed"\n    @Published var reminderTime: String = "12:00"\n    @Published var newMailSubject: String = ""\n',
    "AppState reminder fields",
)
p.write_text(s)

# KeyboardController: all replies are Reply All.
p = root / "app" / "KeyboardController.swift"
s = p.read_text()
s = must_replace(
    s,
    '''    func sendCommandR() {\n        sendKey(code: 15, flags: .maskCommand)\n    }\n''',
    '''    func sendCommandR() {\n        sendKey(code: 15, flags: .maskCommand)\n    }\n\n    func sendCommandShiftR() {\n        sendKey(code: 15, flags: [.maskCommand, .maskShift])\n    }\n''',
    "Keyboard Reply All shortcut",
)
p.write_text(s)

# Outlook accessibility: set a BCC recipient in a compose window.
p = root / "app" / "OutlookAccessibility.swift"
s = p.read_text()
s = must_replace(
    s,
    '''    func setComposeSubjectValue(_ subject: String) -> Bool {\n        guard let window = focusedOutlookWindow(), let element = composeSubjectElement(in: window) else { return false }\n        return setValue(subject, on: element)\n    }\n''',
    '''    func setComposeBCCValue(_ bcc: String) -> Bool {\n        guard let window = focusedOutlookWindow() else { return false }\n        if let element = composeBCCElement(in: window) {\n            return setValue(bcc, on: element)\n        }\n\n        // Some Outlook layouts hide BCC until its small Bcc control is pressed.\n        // Reveal it once, then resolve the actual BCC field again by accessibility metadata.\n        if pressComposeControl(in: window, matching: ["bcc", "blind carbon", "blind copy", "blindkopie"]) ,\n           let refreshed = focusedOutlookWindow(),\n           let element = composeBCCElement(in: refreshed) {\n            return setValue(bcc, on: element)\n        }\n        return false\n    }\n\n    func setComposeSubjectValue(_ subject: String) -> Bool {\n        guard let window = focusedOutlookWindow(), let element = composeSubjectElement(in: window) else { return false }\n        return setValue(subject, on: element)\n    }\n''',
    "Outlook set BCC",
)
anchor = '    private func composeSubjectElement(in window: AXUIElement) -> AXUIElement? {\n'
helper = '''    private func composeBCCElement(in window: AXUIElement) -> AXUIElement? {\n        var stack: [AXUIElement] = [window]\n        var visited = 0\n        while let element = stack.popLast(), visited < 14_000 {\n            visited += 1\n            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""\n            if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" {\n                let meta = composeMetadata(for: element)\n                if meta.contains("bcc") || meta.contains("blind carbon") || meta.contains("blind copy") || meta.contains("blindkopie") {\n                    return element\n                }\n            }\n            for child in children(of: element).reversed() { stack.append(child) }\n        }\n        return nil\n    }\n\n    private func pressComposeControl(in window: AXUIElement, matching needles: [String]) -> Bool {\n        var stack: [AXUIElement] = [window]\n        var visited = 0\n        while let element = stack.popLast(), visited < 14_000 {\n            visited += 1\n            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""\n            if role == "AXButton" || role == "AXCheckBox" || role == "AXMenuButton" {\n                let meta = composeMetadata(for: element)\n                if needles.contains(where: { meta.contains($0) }) {\n                    if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {\n                        return true\n                    }\n                }\n            }\n            for child in children(of: element).reversed() { stack.append(child) }\n        }\n        return false\n    }\n\n'''
if anchor not in s:
    raise SystemExit("compose subject anchor not found")
s = s.replace(anchor, helper + anchor, 1)
p.write_text(s)

# OverlayView: add expandable Reminder row with exclusive weekday choice and time menu.
p = root / "app" / "OverlayView.swift"
s = p.read_text()
old = '''            HStack(spacing: 10) {\n                if state.outputMode == .reply || state.outputMode == .newMail {\n                    HStack(spacing: 7) {\n                        Text("Mood")\n                            .font(.caption)\n                            .foregroundStyle(.secondary)\n                        Picker("Mood", selection: $state.replyTone) {\n                            ForEach(ReplyTone.allCases) { tone in\n                                Text(tone.displayName).tag(tone)\n                            }\n                        }\n                        .labelsHidden()\n                        .pickerStyle(.menu)\n                        .frame(minWidth: 130)\n\n                        Toggle("Compact", isOn: $state.newMailCompact)\n                            .toggleStyle(.checkbox)\n                            .help("Erstellt eine möglichst kurze Mail")\n                    }\n                }\n\n                Spacer()\n\n                if state.outputMode != .payment {\n                    languageButton("🇩🇪", language: .german, help: "Ausgabe auf Deutsch")\n                    languageButton("🇺🇸", language: .usEnglish, help: "Ausgabe in US English")\n                }\n            }\n\n            if state.outputMode == .calendar {\n'''
new = '''            HStack(spacing: 10) {\n                if state.outputMode == .reply || state.outputMode == .newMail {\n                    HStack(spacing: 7) {\n                        Text("Mood")\n                            .font(.caption)\n                            .foregroundStyle(.secondary)\n                        Picker("Mood", selection: $state.replyTone) {\n                            ForEach(ReplyTone.allCases) { tone in\n                                Text(tone.displayName).tag(tone)\n                            }\n                        }\n                        .labelsHidden()\n                        .pickerStyle(.menu)\n                        .frame(minWidth: 130)\n\n                        Toggle("Compact", isOn: $state.newMailCompact)\n                            .toggleStyle(.checkbox)\n                            .help("Erstellt eine möglichst kurze Mail")\n                    }\n                }\n\n                Spacer()\n\n                if state.outputMode != .payment {\n                    languageButton("🇩🇪", language: .german, help: "Ausgabe auf Deutsch")\n                    languageButton("🇺🇸", language: .usEnglish, help: "Ausgabe in US English")\n                }\n            }\n\n            if state.outputMode == .reply || state.outputMode == .newMail {\n                reminderRow\n            }\n\n            if state.outputMode == .calendar {\n'''
s = must_replace(s, old, new, "Overlay reminder insertion")

anchor = '    private var modeSelector: some View {\n'
helper = '''    private var reminderRow: some View {\n        VStack(alignment: .leading, spacing: 9) {\n            HStack(spacing: 8) {\n                Button {\n                    withAnimation(.easeInOut(duration: 0.15)) {\n                        state.reminderEnabled.toggle()\n                    }\n                } label: {\n                    Label("Reminder", systemImage: state.reminderEnabled ? "bell.fill" : "bell")\n                        .font(.system(size: 12.5, weight: .semibold))\n                }\n                .buttonStyle(.bordered)\n                .controlSize(.small)\n\n                if state.reminderEnabled {\n                    Text("BCC")\n                        .font(.caption2)\n                        .foregroundStyle(.tertiary)\n                    Text(reminderAddress)\n                        .font(.caption.monospaced())\n                        .foregroundStyle(.secondary)\n                }\n                Spacer()\n            }\n\n            if state.reminderEnabled {\n                HStack(spacing: 9) {\n                    ForEach(reminderDays, id: \\.code) { day in\n                        Button { state.reminderDay = day.code } label: {\n                            HStack(spacing: 4) {\n                                Image(systemName: state.reminderDay == day.code ? "largecircle.fill.circle" : "circle")\n                                    .font(.system(size: 11))\n                                Text(day.label)\n                                    .font(.system(size: 12, weight: .medium))\n                            }\n                        }\n                        .buttonStyle(.plain)\n                        .contentShape(Rectangle())\n                    }\n\n                    Divider()\n                        .frame(height: 20)\n                        .padding(.horizontal, 2)\n\n                    Picker("Zeit", selection: $state.reminderTime) {\n                        ForEach(reminderTimes, id: \\.self) { time in\n                            Text(time).tag(time)\n                        }\n                    }\n                    .labelsHidden()\n                    .pickerStyle(.menu)\n                    .frame(width: 90)\n                }\n                .padding(.horizontal, 10)\n                .padding(.vertical, 8)\n                .background(.background.opacity(0.42), in: RoundedRectangle(cornerRadius: 9))\n            }\n        }\n    }\n\n    private var reminderDays: [(label: String, code: String)] {\n        [("Mo", "mon"), ("Di", "tue"), ("Mi", "wed"), ("Do", "thu"), ("Fr", "fri"), ("Sa", "sat"), ("So", "sun")]\n    }\n\n    private var reminderTimes: [String] {\n        (0...48).map { slot in\n            if slot == 48 { return "24:00" }\n            let hour = slot / 2\n            let minute = slot % 2 == 0 ? "00" : "30"\n            return "\\(hour):\\(minute)"\n        }\n    }\n\n    private var reminderAddress: String {\n        "\\(state.reminderDay)\\(state.reminderTime)@fut.io"\n    }\n\n'''
if anchor not in s:
    raise SystemExit("mode selector anchor not found")
s = s.replace(anchor, helper + anchor, 1)
p.write_text(s)

# AppDelegate: true icon-only menu bar mark, reset reminder for each compose flow,
# Reply All everywhere, and write reminder address into BCC.
p = root / "app" / "AppDelegate.swift"
s = p.read_text()
old_status = '''        if let url = Bundle.main.url(forResource: "ReplyzenLogo", withExtension: "png"),\n           let image = NSImage(contentsOf: url) {\n            image.size = NSSize(width: 18, height: 18)\n            image.isTemplate = true\n            item.button?.image = image\n        } else if let fallback = NSImage(systemSymbolName: "envelope.badge", accessibilityDescription: "Replyzen") {\n            fallback.isTemplate = true\n            item.button?.image = fallback\n        }\n'''
new_status = '''        if let url = Bundle.main.url(forResource: "ReplyzenLogo", withExtension: "png"),\n           let source = NSImage(contentsOf: url),\n           let image = makeMenuBarTemplateIcon(from: source) {\n            item.button?.image = image\n        } else if let fallback = NSImage(systemSymbolName: "envelope.badge", accessibilityDescription: "Replyzen") {\n            fallback.isTemplate = true\n            item.button?.image = fallback\n        }\n'''
s = must_replace(s, old_status, new_status, "menu bar icon source")

anchor = '    private func configureHotKey() {\n'
helper = '''    private func makeMenuBarTemplateIcon(from source: NSImage) -> NSImage? {\n        let pixels = 36\n        guard let rep = NSBitmapImageRep(\n            bitmapDataPlanes: nil,\n            pixelsWide: pixels,\n            pixelsHigh: pixels,\n            bitsPerSample: 8,\n            samplesPerPixel: 4,\n            hasAlpha: true,\n            isPlanar: false,\n            colorSpaceName: .deviceRGB,\n            bytesPerRow: 0,\n            bitsPerPixel: 0\n        ) else { return nil }\n\n        NSGraphicsContext.saveGraphicsState()\n        if let context = NSGraphicsContext(bitmapImageRep: rep) {\n            NSGraphicsContext.current = context\n            context.imageInterpolation = .high\n            NSColor.white.setFill()\n            NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()\n            source.draw(\n                in: NSRect(x: 1, y: 1, width: pixels - 2, height: pixels - 2),\n                from: .zero,\n                operation: .sourceOver,\n                fraction: 1\n            )\n        }\n        NSGraphicsContext.restoreGraphicsState()\n\n        guard let data = rep.bitmapData else { return nil }\n        let rowBytes = rep.bytesPerRow\n        for y in 0..<pixels {\n            for x in 0..<pixels {\n                let i = y * rowBytes + x * 4\n                let r = Int(data[i])\n                let g = Int(data[i + 1])\n                let b = Int(data[i + 2])\n                let originalAlpha = Int(data[i + 3])\n                let luminance = (r * 30 + g * 59 + b * 11) / 100\n                let darkness = max(0, 255 - luminance)\n                let alpha = darkness * originalAlpha / 255\n                data[i] = 0\n                data[i + 1] = 0\n                data[i + 2] = 0\n                data[i + 3] = UInt8(alpha)\n            }\n        }\n\n        let image = NSImage(size: NSSize(width: 18, height: 18))\n        image.addRepresentation(rep)\n        image.isTemplate = true\n        return image\n    }\n\n'''
if anchor not in s:
    raise SystemExit("hotkey anchor not found")
s = s.replace(anchor, helper + anchor, 1)

# Reset reminder toggle when opening a fresh workspace; keep previous day/time for convenience.
s = must_replace(
    s,
    '''        state.outputMode = .newMail\n        state.instruction = ""\n        state.instructionHTML = ""\n''',
    '''        state.outputMode = .newMail\n        state.instruction = ""\n        state.instructionHTML = ""\n        state.reminderEnabled = false\n''',
    "workspace reminder reset",
)

# Reply and quick decline use Reply All.
s = s.replace('self?.keyboard.sendCommandR()', 'self?.keyboard.sendCommandShiftR()')
s = s.replace('self.keyboard.sendCommandR()', 'self.keyboard.sendCommandShiftR()')

# Helper for fut.io reminder BCC.
anchor = '    private func insertGeneratedText() {\n'
helper = '''    private func reminderBCCAddress() -> String? {\n        guard state.reminderEnabled else { return nil }\n        let day = state.reminderDay.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()\n        let time = state.reminderTime.trimmingCharacters(in: .whitespacesAndNewlines)\n        guard ["mon", "tue", "wed", "thu", "fri", "sat", "sun"].contains(day), !time.isEmpty else { return nil }\n        return "\\(day)\\(time)@fut.io"\n    }\n\n'''
if anchor not in s:
    raise SystemExit("insertGeneratedText anchor not found")
s = s.replace(anchor, helper + anchor, 1)

# In Reply All compose, add reminder BCC before inserting the generated body.
old_reply = '''            DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in\n                guard let self else { return }\n                self.keyboard.sendCommandV()\n                self.isRunningFlow = false\n'''
new_reply = '''            DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in\n                guard let self else { return }\n                if let reminder = self.reminderBCCAddress() {\n                    _ = self.outlook.setComposeBCCValue(reminder)\n                    _ = self.outlook.focusComposeBodyField()\n                    self.copyMailToPasteboard(plainText: reply, html: self.state.replyHTML)\n                }\n                self.keyboard.sendCommandV()\n                self.isRunningFlow = false\n'''
s = must_replace(s, old_reply, new_reply, "Reply reminder BCC")

# New Mail: set BCC while Outlook compose fields are available.
s = must_replace(
    s,
    '''            let subjectDone = subject.isEmpty || self.outlook.setComposeSubjectValue(subject)\n            // Accessibility can set plain text directly, but rich formatting must be\n''',
    '''            let subjectDone = subject.isEmpty || self.outlook.setComposeSubjectValue(subject)\n            let reminderDone: Bool\n            if let reminder = self.reminderBCCAddress() {\n                reminderDone = self.outlook.setComposeBCCValue(reminder)\n            } else {\n                reminderDone = true\n            }\n            // Accessibility can set plain text directly, but rich formatting must be\n''',
    "New Mail reminder BCC attempt",
)
s = must_replace(
    s,
    '''            if html.isEmpty, self.outlook.setComposeBodyValue(body) {\n                self.finishNewMailInsertion()\n                return\n            }\n''',
    '''            if html.isEmpty, reminderDone, self.outlook.setComposeBodyValue(body) {\n                self.finishNewMailInsertion()\n                return\n            }\n''',
    "New Mail reminder direct body",
)
s = must_replace(
    s,
    '''            if attempt < 2 {\n                self.populateNewMailDraft(subject: subject, body: body, html: html, attempt: attempt + 1)\n                return\n            }\n''',
    '''            if attempt < 2 {\n                self.populateNewMailDraft(subject: subject, body: body, html: html, attempt: attempt + 1)\n                return\n            }\n\n            if !reminderDone, let reminder = self.reminderBCCAddress() {\n                _ = self.outlook.setComposeBCCValue(reminder)\n            }\n''',
    "New Mail reminder final attempt",
)
p.write_text(s)

# Version and build metadata.
p = root / "app" / "Info.plist"
s = p.read_text()
s = must_replace(s, '<string>1.29.0</string>', '<string>1.30.0</string>', "Info version")
s = must_replace(s, '<string>30</string>', '<string>31</string>', "Info build")
p.write_text(s)

p = root / "Build-CI.sh"
s = p.read_text()
s = s.replace('Replyzen-update-1.29.zip', 'Replyzen-update-1.30.zip')
s = must_replace(
    s,
    '"notes": "Replyzen 1.29: Größeres WYSIWYG Textfeld in der Mail Hauptansicht, aufgeräumte GUI und feste Aktionsleiste unten mit Schließen links und Erstellen rechts. In der macOS Menüleiste erscheint nur noch das Replyzen Logo ohne Schriftzug; das Icon folgt automatisch dem Hell und Dunkelmodus."',
    '"notes": "Replyzen 1.30: Reply verwendet immer Reply All. Optionaler Reminder in der Mail Ansicht mit Mo bis So und Uhrzeit 0:00 bis 24:00; bei Aktivierung wird automatisch z. B. wed12:00@fut.io in BCC gesetzt. Das macOS Menüleisten Icon wird aus dem Replyzen App Logo als transparente Template Maske erzeugt, damit kein weißes Quadrat mehr erscheint."',
    "Build notes",
)
p.write_text(s)
