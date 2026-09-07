from pathlib import Path
import sys

root = Path(sys.argv[1])


def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f"{label} not found")
    return text.replace(old, new, 1)

# AppState: Forward is a first-class Mail mode so the same Replyzen form can be used.
p = root / "app" / "AppState.swift"
s = p.read_text()
s = must_replace(
    s,
    '''        case reply\n        case newMail\n        case calendar\n''',
    '''        case reply\n        case newMail\n        case forward\n        case calendar\n''',
    "AppState forward mode",
)
s = must_replace(
    s,
    '''            case .reply: return "Reply"\n            case .newMail: return "New Mail"\n            case .calendar: return "Termin"\n''',
    '''            case .reply: return "Reply"\n            case .newMail: return "New Mail"\n            case .forward: return "Forward"\n            case .calendar: return "Termin"\n''',
    "AppState forward display name",
)
p.write_text(s)

# Toolbar: move the floating overlay down so it no longer covers Outlook Search.
# Forward now opens Replyzen rather than forwarding immediately.
p = root / "app" / "OutlookToolbarButtonController.swift"
s = p.read_text()
s = must_replace(
    s,
    '        forwardButton = makeButton(title: "Forward", symbol: "arrowshape.turn.up.right", x: 252, width: 88, help: "Aktuelle Mail in Outlook weiterleiten")\n',
    '        forwardButton = makeButton(title: "Forward", symbol: "arrowshape.turn.up.right", x: 252, width: 88, help: "Aktuelle Mail mit Replyzen weiterleiten")\n',
    "forward toolbar help",
)
s = must_replace(
    s,
    '        let y = frame.maxY - size.height - 10\n',
    '        let y = frame.maxY - size.height - 48\n',
    "toolbar lower position",
)
p.write_text(s)

# Keyboard: after Outlook opens a native forward, Command+Up places the caret
# above the forwarded thread before Replyzen pastes the note.
p = root / "app" / "KeyboardController.swift"
s = p.read_text()
s = must_replace(
    s,
    '''    func sendCommandV() {\n        sendKey(code: 9, flags: .maskCommand)\n    }\n''',
    '''    func sendCommandV() {\n        sendKey(code: 9, flags: .maskCommand)\n    }\n\n    func sendCommandUp() {\n        sendKey(code: 126, flags: .maskCommand)\n    }\n''',
    "keyboard command up",
)
p.write_text(s)

# OverlayView: Forward uses the same WYSIWYG Mail form. The entered text is used
# directly, so Mood/Compact/language are intentionally not shown for Forward.
p = root / "app" / "OverlayView.swift"
s = p.read_text()
s = must_replace(
    s,
    '''        case .reply: return "Ich erstelle deine Antwort …"\n        case .newMail: return "Ich formuliere deine neue Mail …"\n        case .calendar: return "Ich erstelle einen kurzen Termintitel und erkenne den Zeitpunkt …"\n''',
    '''        case .reply: return "Ich erstelle deine Antwort …"\n        case .newMail: return "Ich formuliere deine neue Mail …"\n        case .forward: return "Ich bereite die Weiterleitung vor …"\n        case .calendar: return "Ich erstelle einen kurzen Termintitel und erkenne den Zeitpunkt …"\n''',
    "forward generating subtitle",
)
s = must_replace(
    s,
    '''    private var insertingSubtitle: String {\n        state.outputMode == .newMail\n            ? "Ich öffne eine neue Outlook-Mail und setze den Text ein …"\n            : "Ich setze die Antwort in Outlook ein …"\n    }\n''',
    '''    private var insertingSubtitle: String {\n        switch state.outputMode {\n        case .newMail:\n            return "Ich öffne eine neue Outlook-Mail und setze den Text ein …"\n        case .forward:\n            return "Ich öffne die Outlook-Weiterleitung und setze deinen Text über den Thread …"\n        case .reply:\n            return "Ich setze die Antwort in Outlook ein …"\n        case .calendar, .payment:\n            return "Fast fertig …"\n        }\n    }\n''',
    "forward inserting subtitle",
)
s = must_replace(
    s,
    '            if state.outputMode == .reply || state.outputMode == .newMail {\n                mailTypeSelector\n',
    '            if state.outputMode == .reply || state.outputMode == .newMail || state.outputMode == .forward {\n                mailTypeSelector\n',
    "forward mail selector visibility",
)
s = must_replace(
    s,
    '''                if state.outputMode != .payment {\n                    languageButton("🇩🇪", language: .german, help: "Ausgabe auf Deutsch")\n                    languageButton("🇺🇸", language: .usEnglish, help: "Ausgabe in US English")\n                }\n''',
    '''                if state.outputMode != .payment && state.outputMode != .forward {\n                    languageButton("🇩🇪", language: .german, help: "Ausgabe auf Deutsch")\n                    languageButton("🇺🇸", language: .usEnglish, help: "Ausgabe in US English")\n                }\n''',
    "hide language on forward",
)
s = must_replace(
    s,
    '            if state.outputMode == .reply || state.outputMode == .newMail {\n                reminderRow\n',
    '            if state.outputMode == .reply || state.outputMode == .newMail || state.outputMode == .forward {\n                reminderRow\n',
    "forward reminder visibility",
)
s = must_replace(
    s,
    '''        HStack(spacing: 8) {\n            if mailAvailable {\n                mailTypeButton(.reply, title: "Reply", systemImage: "arrowshape.turn.up.left.fill")\n            }\n            mailTypeButton(.newMail, title: "New Mail", systemImage: "square.and.pencil")\n\n            if !mailAvailable {\n''',
    '''        HStack(spacing: 8) {\n            if mailAvailable {\n                mailTypeButton(.reply, title: "Reply", systemImage: "arrowshape.turn.up.left.fill")\n            }\n            mailTypeButton(.newMail, title: "New Mail", systemImage: "square.and.pencil")\n            if mailAvailable {\n                mailTypeButton(.forward, title: "Forward", systemImage: "arrowshape.turn.up.right")\n            }\n\n            if !mailAvailable {\n''',
    "forward mail button",
)
s = s.replace('Text("Keine Mail erkannt. Reply ist ausgeblendet.")', 'Text("Keine Mail erkannt. Reply und Forward sind ausgeblendet.")')
s = must_replace(
    s,
    '''        if mode == .reply {\n            return state.outputMode == .reply || state.outputMode == .newMail\n        }\n''',
    '''        if mode == .reply {\n            return state.outputMode == .reply || state.outputMode == .newMail || state.outputMode == .forward\n        }\n''',
    "forward top level mail selection",
)
s = must_replace(
    s,
    '''        case .reply: return "Antwort erstellen"\n        case .newMail: return "Mail erstellen"\n        case .calendar: return "Termin erstellen"\n''',
    '''        case .reply: return "Antwort erstellen"\n        case .newMail: return "Mail erstellen"\n        case .forward: return "In Outlook weiterleiten"\n        case .calendar: return "Termin erstellen"\n''',
    "forward primary action title",
)
s = must_replace(
    s,
    '''        case .reply:\n            return !mailAvailable || state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty\n        case .newMail:\n            return state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty\n        case .calendar, .payment:\n''',
    '''        case .reply:\n            return !mailAvailable || state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty\n        case .newMail:\n            return state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty\n        case .forward:\n            return !mailAvailable || state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty\n        case .calendar, .payment:\n''',
    "forward primary action disabled",
)
s = must_replace(
    s,
    '''        case .reply:\n            if state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {\n                state.instruction = state.replyLanguage == .german\n                    ? "Kurz, freundlich und direkt antworten."\n                    : "Reply briefly, friendly and directly."\n                state.instructionHTML = ""\n            }\n        case .calendar, .payment:\n''',
    '''        case .reply:\n            if state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {\n                state.instruction = state.replyLanguage == .german\n                    ? "Kurz, freundlich und direkt antworten."\n                    : "Reply briefly, friendly and directly."\n                state.instructionHTML = ""\n            }\n        case .forward:\n            let trimmed = state.instruction.trimmingCharacters(in: .whitespacesAndNewlines)\n            if trimmed == "Kurz, freundlich und direkt antworten." ||\n               trimmed == "Reply briefly, friendly and directly." {\n                state.instruction = ""\n                state.instructionHTML = ""\n            }\n        case .calendar, .payment:\n''',
    "forward mode change",
)
s = must_replace(
    s,
    '''        case .reply: return "Antwortvorschlag"\n        case .newMail: return "Neue Mail"\n        case .calendar: return "Termin"\n''',
    '''        case .reply: return "Antwortvorschlag"\n        case .newMail: return "Neue Mail"\n        case .forward: return "Weiterleitung"\n        case .calendar: return "Termin"\n''',
    "forward preview title",
)
p.write_text(s)

# Floating panel: Forward uses the large Mail workspace size.
p = root / "app" / "FloatingPanelController.swift"
s = p.read_text()
s = must_replace(
    s,
    '            case .reply, .newMail:\n                return NSSize(width: 900, height: 800)\n',
    '            case .reply, .newMail, .forward:\n                return NSSize(width: 900, height: 800)\n',
    "forward panel size",
)
p.write_text(s)

# AppDelegate: Forward opens the Replyzen form, uses the WYSIWYG text exactly as
# entered, then opens Outlook's native Forward so original thread and attachments
# remain intact. No recipient is filled by Replyzen.
p = root / "app" / "AppDelegate.swift"
s = p.read_text()
s = must_replace(
    s,
    '        toolbarButton.forwardAction = { [weak self] in self?.forwardCurrentMail() }\n',
    '        toolbarButton.forwardAction = { [weak self] in self?.openForwardWorkspace() }\n',
    "forward toolbar action",
)
s = must_replace(
    s,
    '''    private func forwardCurrentMail() {\n        guard !isRunningFlow else { return }\n        guard let pid = outlook.runningPID() else { return }\n        guard outlook.isTrusted() else {\n            outlook.requestTrustPrompt()\n            return\n        }\n\n        toolbarButton.setSuppressed(true)\n        outlook.activateOutlook(pid: pid)\n        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in\n            self?.keyboard.sendCommandJ()\n            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {\n                self?.toolbarButton.setSuppressed(false)\n            }\n        }\n    }\n''',
    '''    private func openForwardWorkspace() {\n        requestedMailMode = .forward\n        replyAllForCurrentDraft = true\n        openWorkspace()\n    }\n''',
    "forward workspace opener",
)
s = must_replace(
    s,
    '''        if requestedMailMode == .reply {\n            state.outputMode = .reply\n            state.instruction = defaultReplyInstruction(for: state.replyLanguage)\n        } else {\n            state.outputMode = .newMail\n            state.instruction = ""\n        }\n''',
    '''        if requestedMailMode == .reply {\n            state.outputMode = .reply\n            state.instruction = defaultReplyInstruction(for: state.replyLanguage)\n        } else if requestedMailMode == .forward {\n            state.outputMode = .forward\n            state.instruction = ""\n        } else {\n            state.outputMode = .newMail\n            state.instruction = ""\n        }\n''',
    "open forward workspace mode",
)
s = must_replace(
    s,
    '''                    if self.requestedMailMode == .reply {\n                        self.state.outputMode = .reply\n                    } else if self.requestedMailMode == .newMail {\n                        self.state.outputMode = .newMail\n                    } else if self.state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {\n''',
    '''                    if self.requestedMailMode == .reply {\n                        self.state.outputMode = .reply\n                    } else if self.requestedMailMode == .forward {\n                        self.state.outputMode = .forward\n                    } else if self.requestedMailMode == .newMail {\n                        self.state.outputMode = .newMail\n                    } else if self.state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {\n''',
    "refresh forward mode",
)
s = must_replace(
    s,
    '''        case .reply:\n            generateReply()\n        case .newMail:\n            generateNewMail()\n        case .calendar:\n''',
    '''        case .reply:\n            generateReply()\n        case .newMail:\n            generateNewMail()\n        case .forward:\n            forwardWithNote()\n        case .calendar:\n''',
    "generate forward route",
)
anchor = '    private func generateCalendarSuggestion() {\n'
forward_func = '''    private func forwardWithNote() {\n        let body = state.instruction.trimmingCharacters(in: .whitespacesAndNewlines)\n        guard !body.isEmpty else { return }\n        guard !state.mailText.isEmpty, activeSnapshot != nil else {\n            state.mailStatus = .unavailable("Keine lesbare Outlook-Mail erkannt. Für Forward bitte eine Mail öffnen und erneut versuchen.")\n            return\n        }\n\n        state.reply = body\n        state.replyHTML = state.instructionHTML\n        insertForwardDraft()\n    }\n\n'''
if anchor not in s:
    raise SystemExit("forward function anchor not found")
s = s.replace(anchor, forward_func + anchor, 1)
s = must_replace(
    s,
    '''        case .reply:\n            insertReply()\n        case .newMail:\n            insertNewMail()\n        case .calendar, .payment:\n''',
    '''        case .reply:\n            insertReply()\n        case .newMail:\n            insertNewMail()\n        case .forward:\n            insertForwardDraft()\n        case .calendar, .payment:\n''',
    "insert forward route",
)
anchor = '    private func insertNewMail() {\n'
insert_forward = '''    private func insertForwardDraft() {\n        guard let snapshot = activeSnapshot else {\n            state.stage = .instruction\n            state.mailStatus = .unavailable("Die ursprüngliche Outlook-Mail ist nicht mehr verfügbar. Bitte erneut laden.")\n            return\n        }\n\n        let body = state.reply.trimmingCharacters(in: .whitespacesAndNewlines)\n        let html = state.replyHTML.trimmingCharacters(in: .whitespacesAndNewlines)\n        guard !body.isEmpty else { return }\n\n        guard outlook.isTrusted() else {\n            copyMailToPasteboard(plainText: body, html: html)\n            showError("Replyzen braucht Bedienungshilfen, um den Forward automatisch in Outlook vorzubereiten. Dein Text wurde in die Zwischenablage kopiert.")\n            return\n        }\n\n        state.stage = .inserting\n        state.statusText = "Outlook Forward wird geöffnet; Thread und Anhänge bleiben erhalten"\n        isRunningFlow = true\n        toolbarButton.setSuppressed(true)\n        panel.hide()\n        outlook.activateOutlook(pid: snapshot.pid)\n\n        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in\n            guard let self else { return }\n            self.keyboard.sendCommandJ()\n            self.populateForwardDraft(body: body, html: html, attempt: 0)\n        }\n    }\n\n    private func populateForwardDraft(body: String, html: String, attempt: Int) {\n        let delay = attempt == 0 ? 0.95 : 0.28\n        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in\n            guard let self else { return }\n\n            if let reminder = self.reminderBCCAddress() {\n                _ = self.outlook.setComposeBCCValue(reminder)\n            }\n\n            if self.outlook.focusComposeBodyField() {\n                // Native Outlook Forward preserves the original message and its attachments.\n                // Move to the very top and paste only the user's Replyzen note above it.\n                self.keyboard.sendCommandUp()\n                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in\n                    guard let self else { return }\n                    let plain = body + "\\n\\n"\n                    let rich = html.isEmpty ? "" : html + "<br><br>"\n                    self.copyMailToPasteboard(plainText: plain, html: rich)\n                    self.keyboard.sendCommandV()\n                    self.finishNewMailInsertion()\n                }\n                return\n            }\n\n            if attempt < 3 {\n                self.populateForwardDraft(body: body, html: html, attempt: attempt + 1)\n                return\n            }\n\n            self.copyMailToPasteboard(plainText: body, html: html)\n            self.isRunningFlow = false\n            self.showError("Der Forward wurde in Outlook geöffnet, aber Replyzen konnte den Text nicht automatisch über dem Thread einsetzen. Der Text liegt in der Zwischenablage.")\n        }\n    }\n\n'''
if anchor not in s:
    raise SystemExit("insert new mail anchor not found")
s = s.replace(anchor, insert_forward + anchor, 1)
p.write_text(s)

# Version and release metadata.
p = root / "app" / "Info.plist"
s = p.read_text()
s = s.replace('<string>1.32.0</string>', '<string>1.33.0</string>', 1)
s = s.replace('<string>33</string>', '<string>34</string>', 1)
p.write_text(s)

p = root / "Build-CI.sh"
s = p.read_text()
s = s.replace('Replyzen-update-1.32.zip', 'Replyzen-update-1.33.zip')
s = s.replace(
    'Replyzen 1.32: Das Outlook Overlay zeigt jetzt genau New, Reply, Reply All, Forward und Cancel. Reply antwortet nur dem Absender, Reply All allen Empfängern, Forward öffnet direkt Outlook Weiterleiten und Cancel erstellt weiterhin eine kurze freundliche Absage. Der normale Replyzen Reply bleibt standardmäßig Reply All.',
    'Replyzen 1.33: Das Outlook Overlay sitzt tiefer und verdeckt die Outlook Suche nicht mehr. Forward öffnet jetzt zuerst Replyzen. Der dort eingegebene WYSIWYG Text wird unverändert oberhalb des nativen Outlook Forward Threads eingesetzt; Empfänger bleibt leer und Outlook behält ursprünglichen Thread und Anhänge.'
)
p.write_text(s)
