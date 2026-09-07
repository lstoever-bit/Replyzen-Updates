from pathlib import Path
import sys

root = Path(sys.argv[1])


def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f"{label} not found")
    return text.replace(old, new, 1)

# 1) Outlook overlay: keep the subtle Replyzen background, add Payment after Termin.
p = root / "app" / "OutlookToolbarButtonController.swift"
s = p.read_text()
s = must_replace(
    s,
    '''    private let cancelButton: NSButton\n    private let calendarButton: NSButton\n''',
    '''    private let cancelButton: NSButton\n    private let calendarButton: NSButton\n    private let paymentButton: NSButton\n''',
    "toolbar payment declaration",
)
s = must_replace(
    s,
    '''    var cancelAction: (() -> Void)?\n    var calendarAction: (() -> Void)?\n''',
    '''    var cancelAction: (() -> Void)?\n    var calendarAction: (() -> Void)?\n    var paymentAction: (() -> Void)?\n''',
    "toolbar payment action",
)
s = must_replace(s, '        let size = NSSize(width: 540, height: 34)\n', '        let size = NSSize(width: 646, height: 34)\n', "toolbar size")
s = must_replace(
    s,
    '''        calendarButton = makeButton(title: "Termin", symbol: "calendar.badge.plus", x: 444, width: 92, help: "Termin aus der aktuellen Mail mit Replyzen erstellen")\n\n        effect.addSubview(newButton)\n''',
    '''        calendarButton = makeButton(title: "Termin", symbol: "calendar.badge.plus", x: 444, width: 92, help: "Termin aus der aktuellen Mail mit Replyzen erstellen")\n        paymentButton = makeButton(title: "Überweisung", symbol: "banknote", x: 540, width: 102, help: "Überweisungsdaten aus der aktuellen Mail und PDF extrahieren")\n\n        effect.addSubview(newButton)\n''',
    "toolbar payment setup",
)
s = must_replace(
    s,
    '''        effect.addSubview(cancelButton)\n        effect.addSubview(calendarButton)\n''',
    '''        effect.addSubview(cancelButton)\n        effect.addSubview(calendarButton)\n        effect.addSubview(paymentButton)\n''',
    "toolbar payment subview",
)
s = must_replace(
    s,
    '''        calendarButton.target = self\n        calendarButton.action = #selector(calendarClicked)\n''',
    '''        calendarButton.target = self\n        calendarButton.action = #selector(calendarClicked)\n        paymentButton.target = self\n        paymentButton.action = #selector(paymentClicked)\n''',
    "toolbar payment target",
)
s = must_replace(
    s,
    '''    @objc private func calendarClicked() { calendarAction?() }\n''',
    '''    @objc private func calendarClicked() { calendarAction?() }\n    @objc private func paymentClicked() { paymentAction?() }\n''',
    "toolbar payment selector",
)
p.write_text(s)

# 2) Main Replyzen mail form: remove the obsolete top-level Mail / Überweisung selector.
p = root / "app" / "OverlayView.swift"
s = p.read_text()
s = must_replace(
    s,
    '''            modeSelector\n\n            if state.outputMode == .reply || state.outputMode == .newMail || state.outputMode == .forward {\n''',
    '''            if state.outputMode == .reply || state.outputMode == .newMail || state.outputMode == .forward {\n''',
    "remove top-level mode selector",
)
p.write_text(s)

# 3) AppDelegate: payment is now a direct overlay workflow just like Termin.
p = root / "app" / "AppDelegate.swift"
s = p.read_text()
s = must_replace(
    s,
    '''        toolbarButton.cancelAction = { [weak self] in self?.quickDecline() }\n        toolbarButton.calendarAction = { [weak self] in self?.createCalendarFromOverlay() }\n        toolbarButton.start()\n''',
    '''        toolbarButton.cancelAction = { [weak self] in self?.quickDecline() }\n        toolbarButton.calendarAction = { [weak self] in self?.createCalendarFromOverlay() }\n        toolbarButton.paymentAction = { [weak self] in self?.createPaymentFromOverlay() }\n        toolbarButton.start()\n''',
    "configure payment overlay action",
)

calendar_anchor = '''    private func quickDecline() {\n'''
payment_method = '''    private func createPaymentFromOverlay() {\n        guard !isRunningFlow else { return }\n        // Warm/load the API key before starting the hidden flow. KeychainStore caches\n        // it for the rest of the app session, so the extractor can reuse it.\n        guard keychain.loadAPIKey() != nil else {\n            toolbarButton.setSuppressed(true)\n            state.apiKeyDraft = ""\n            state.stage = .apiKey\n            panel.show()\n            return\n        }\n        guard outlook.isTrusted() else {\n            outlook.requestTrustPrompt()\n            return\n        }\n\n        isRunningFlow = true\n        toolbarButton.setSuppressed(true)\n\n        DispatchQueue.global(qos: .userInitiated).async { [weak self] in\n            guard let self else { return }\n\n            do {\n                var snapshot = try self.outlook.captureSnapshot(includeAllWindows: false)\n                var mail: String\n                do {\n                    mail = try self.outlook.readMail(from: snapshot)\n                } catch OutlookAccessibility.OutlookError.noMailText {\n                    snapshot = try self.outlook.captureSnapshot(includeAllWindows: true)\n                    mail = try self.outlook.readMail(from: snapshot)\n                }\n\n                DispatchQueue.main.async {\n                    self.activeSnapshot = snapshot\n                    self.state.mailText = mail\n                    self.state.mailStatus = .available\n                    self.state.outputMode = .payment\n                    // Do not show the normal Replyzen form. The existing extractor\n                    // opens only the editable payment result window when finished.\n                    self.generatePaymentSuggestion()\n                }\n            } catch {\n                DispatchQueue.main.async {\n                    self.isRunningFlow = false\n                    self.toolbarButton.setSuppressed(false)\n                    self.showSimpleAlert(\n                        title: "Überweisung nicht erkannt",\n                        message: "Die geöffnete Outlook-Mail konnte nicht gelesen werden."\n                    )\n                }\n            }\n        }\n    }\n\n'''
if calendar_anchor not in s:
    raise SystemExit("quick decline anchor not found")
s = s.replace(calendar_anchor, payment_method + calendar_anchor, 1)

# 4) Forward insertion: Classic Outlook often exposes the Subject field but not the
# HTML body as an AXTextArea. If direct body focus fails, focus Subject and Tab once
# into the native body, then paste at the very top. This preserves Outlook's native
# forward thread and attachments.
old_forward = '''            if self.outlook.focusComposeBodyField() {\n                // Native Outlook Forward preserves the original message and its attachments.\n                // Move to the very top and paste only the user's Replyzen note above it.\n                self.keyboard.sendCommandUp()\n                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in\n                    guard let self else { return }\n                    let plain = body + "\\n\\n"\n                    let rich = html.isEmpty ? "" : html + "<br><br>"\n                    self.copyMailToPasteboard(plainText: plain, html: rich)\n                    self.keyboard.sendCommandV()\n                    self.finishNewMailInsertion()\n                }\n                return\n            }\n\n            if attempt < 3 {\n'''
new_forward = '''            if self.outlook.focusComposeBodyField() {\n                // Native Outlook Forward preserves the original message and its attachments.\n                // Move to the very top and paste only the user's Replyzen note above it.\n                self.keyboard.sendCommandUp()\n                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in\n                    guard let self else { return }\n                    let plain = body + "\\n\\n"\n                    let rich = html.isEmpty ? "" : html + "<br><br>"\n                    self.copyMailToPasteboard(plainText: plain, html: rich)\n                    self.keyboard.sendCommandV()\n                    self.finishNewMailInsertion()\n                }\n                return\n            }\n\n            // Legacy Outlook may not expose its HTML compose body through AX at all.\n            // The subject field is exposed reliably, and one Tab from Subject enters\n            // the native message body. Use that as a robust fallback.\n            if self.outlook.focusComposeSubjectField() {\n                self.keyboard.sendTab()\n                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in\n                    guard let self else { return }\n                    self.keyboard.sendCommandUp()\n                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in\n                        guard let self else { return }\n                        let plain = body + "\\n\\n"\n                        let rich = html.isEmpty ? "" : html + "<br><br>"\n                        self.copyMailToPasteboard(plainText: plain, html: rich)\n                        self.keyboard.sendCommandV()\n                        self.finishNewMailInsertion()\n                    }\n                }\n                return\n            }\n\n            if attempt < 3 {\n'''
s = must_replace(s, old_forward, new_forward, "forward subject-tab fallback")
p.write_text(s)

# 5) Version and release metadata.
p = root / "app" / "Info.plist"
s = p.read_text()
s = s.replace('<string>1.36.0</string>', '<string>1.37.0</string>', 1)
s = s.replace('<string>37</string>', '<string>38</string>', 1)
p.write_text(s)

p = root / "Build-CI.sh"
s = p.read_text()
s = s.replace('Replyzen-update-1.36.zip', 'Replyzen-update-1.37.zip')
s = s.replace(
    'Replyzen 1.36: Termin startet jetzt direkt aus dem Outlook Overlay. Replyzen liest die aktuelle Mail, erkennt die Sprache und fragt OpenAI sofort; erst das fertige editierbare Termin Ergebnisfenster wird angezeigt. OpenAI Keychain Zugriffe werden innerhalb eines App Starts gecacht.',
    'Replyzen 1.37: Forward Einsetzen in Legacy Outlook ist robuster und nutzt bei Bedarf den Subject-Tab-Fallback. Überweisung startet jetzt direkt aus dem Outlook Overlay und zeigt erst das extrahierte Ergebnisfenster. Die Hauptansicht hat keinen Mail/Überweisung Modusschalter mehr. Der dezente Overlay Hintergrund bleibt erhalten.'
)
p.write_text(s)
