from pathlib import Path
import sys

root = Path(sys.argv[1])


def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f"{label} not found")
    return text.replace(old, new, 1)

# --- Outlook overlay: add Termin after Cancel, keep the lowered position. ---
p = root / "app" / "OutlookToolbarButtonController.swift"
s = p.read_text()
s = must_replace(
    s,
    '''    private let forwardButton: NSButton\n    private let cancelButton: NSButton\n''',
    '''    private let forwardButton: NSButton\n    private let cancelButton: NSButton\n    private let calendarButton: NSButton\n''',
    "toolbar calendar declaration",
)
s = must_replace(
    s,
    '''    var forwardAction: (() -> Void)?\n    var cancelAction: (() -> Void)?\n''',
    '''    var forwardAction: (() -> Void)?\n    var cancelAction: (() -> Void)?\n    var calendarAction: (() -> Void)?\n''',
    "toolbar calendar action",
)
s = must_replace(s, '        let size = NSSize(width: 448, height: 34)\n', '        let size = NSSize(width: 540, height: 34)\n', "toolbar width")
s = must_replace(
    s,
    '''        cancelButton = makeButton(title: "Cancel", symbol: "xmark.circle", x: 344, width: 96, help: "Freundliche kurze Absage direkt als Antwort einsetzen")\n\n        effect.addSubview(newButton)\n        effect.addSubview(replyButton)\n        effect.addSubview(replyAllButton)\n        effect.addSubview(forwardButton)\n        effect.addSubview(cancelButton)\n''',
    '''        cancelButton = makeButton(title: "Cancel", symbol: "xmark.circle", x: 344, width: 96, help: "Freundliche kurze Absage direkt als Antwort einsetzen")\n        calendarButton = makeButton(title: "Termin", symbol: "calendar.badge.plus", x: 444, width: 92, help: "Termin aus der aktuellen Mail mit Replyzen erstellen")\n\n        effect.addSubview(newButton)\n        effect.addSubview(replyButton)\n        effect.addSubview(replyAllButton)\n        effect.addSubview(forwardButton)\n        effect.addSubview(cancelButton)\n        effect.addSubview(calendarButton)\n''',
    "toolbar calendar setup",
)
s = must_replace(
    s,
    '''        cancelButton.target = self\n        cancelButton.action = #selector(cancelClicked)\n''',
    '''        cancelButton.target = self\n        cancelButton.action = #selector(cancelClicked)\n        calendarButton.target = self\n        calendarButton.action = #selector(calendarClicked)\n''',
    "toolbar calendar target",
)
s = must_replace(
    s,
    '''    @objc private func forwardClicked() { forwardAction?() }\n    @objc private func cancelClicked() { cancelAction?() }\n''',
    '''    @objc private func forwardClicked() { forwardAction?() }\n    @objc private func cancelClicked() { cancelAction?() }\n    @objc private func calendarClicked() { calendarAction?() }\n''',
    "toolbar calendar selector",
)
p.write_text(s)

# --- Main GUI: New, Reply and Forward use exactly the same Mail form controls.
# Termin is no longer a top-level button in the Replyzen main view. ---
p = root / "app" / "OverlayView.swift"
s = p.read_text()
s = must_replace(
    s,
    '                if state.outputMode == .reply || state.outputMode == .newMail {\n',
    '                if state.outputMode == .reply || state.outputMode == .newMail || state.outputMode == .forward {\n',
    "mood and compact for forward",
)
s = must_replace(
    s,
    '                if state.outputMode != .payment && state.outputMode != .forward {\n',
    '                if state.outputMode != .payment {\n',
    "language for forward",
)
s = must_replace(
    s,
    '''        HStack(spacing: 8) {\n            modeButton(.reply, title: "Mail", systemImage: "envelope.fill")\n            modeButton(.calendar, title: "Termin", systemImage: "calendar.badge.plus")\n            modeButton(.payment, title: "Überweisung", systemImage: "banknote")\n        }\n''',
    '''        HStack(spacing: 8) {\n            modeButton(.reply, title: "Mail", systemImage: "envelope.fill")\n            modeButton(.payment, title: "Überweisung", systemImage: "banknote")\n        }\n''',
    "remove calendar from main mode selector",
)
s = must_replace(
    s,
    '        case .forward: return "In Outlook weiterleiten"\n',
    '        case .forward: return "Forward erstellen"\n',
    "forward primary action",
)
p.write_text(s)

# --- OpenAI: Forward gets the same AI drafting controls as Reply/New Mail. ---
p = root / "app" / "OpenAIClient.swift"
s = p.read_text()
marker = '''    func generateQuickDecline(\n'''
if marker not in s:
    raise SystemExit("OpenAI quick decline marker not found")
forward_method = '''    func generateForwardNote(\n        apiKey: String,\n        mailText: String,\n        instruction: String,\n        instructionHTML: String,\n        tone: ReplyTone,\n        language: AppState.ReplyLanguage,\n        compact: Bool,\n        completion: @escaping (Result<ReplyDraft, Error>) -> Void\n    ) {\n        var systemInstructions = [\n            "Draft the short note that the user will place above an existing forwarded email thread.",\n            "Return ONLY valid JSON with exactly these keys: body, html.",\n            "body is the plain text forwarding note only.",\n            "html is the same note as a clean email safe HTML fragment. Use only p, br, strong, em, ul, ol and li. Do not use CSS, script, html or body tags.",\n            "If the user's rich text instruction intentionally uses bold, italic, bullets or numbering, preserve that formatting in the final note where it makes sense.",\n            "The original email thread and attachments will be preserved by Outlook below this note. Do not reproduce or summarize the whole forwarded thread unless the user explicitly asks for that.",\n            "Do not invent a recipient. Do not add To, CC, BCC or a subject line.",\n            "Do not add a signature or the user's name unless explicitly requested.",\n            "Be concise, natural, and appropriate for email.",\n            tone.apiInstruction,\n            restrainedDashInstruction,\n            languageInstruction(for: language, purpose: "forwarding note"),\n            "Follow the user's instruction precisely. The language of the instruction is input only and must never override the selected output language.",\n            "Do not invent facts, promises, dates, attachments, or commitments."\n        ]\n        if compact {\n            systemInstructions.append("COMPACT MODE IS ON: make the forwarding note as short as possible while preserving the requested meaning. Prefer 1 to 3 short sentences and normally stay under 70 words.")\n        }\n\n        let richInstruction = instructionHTML.trimmingCharacters(in: .whitespacesAndNewlines)\n        let input = "USER INSTRUCTION PLAIN:\\n\\(instruction)" +\n            (richInstruction.isEmpty ? "" : "\\n\\nUSER INSTRUCTION HTML FORMATTING CUES:\\n\\(richInstruction)") +\n            "\\n\\nEMAIL BEING FORWARDED:\\n\\(String(mailText.prefix(30_000)))"\n\n        performRequest(\n            apiKey: apiKey,\n            instructions: systemInstructions.joined(separator: "\\n"),\n            input: input,\n            maxOutputTokens: compact ? 340 : 700,\n            lowVerbosity: true\n        ) { result in\n            switch result {\n            case .success(let text):\n                do { completion(.success(try Self.decodeReplyDraft(text))) }\n                catch { completion(.failure(error)) }\n            case .failure(let error):\n                completion(.failure(error))\n            }\n        }\n    }\n\n'''
s = s.replace(marker, forward_method + marker, 1)
p.write_text(s)

# --- AppDelegate: Forward generates via OpenAI with the same form controls;
# Termin is opened only through the Outlook overlay. ---
p = root / "app" / "AppDelegate.swift"
s = p.read_text()
s = must_replace(
    s,
    '''        toolbarButton.forwardAction = { [weak self] in self?.openForwardWorkspace() }\n        toolbarButton.cancelAction = { [weak self] in self?.quickDecline() }\n        toolbarButton.start()\n''',
    '''        toolbarButton.forwardAction = { [weak self] in self?.openForwardWorkspace() }\n        toolbarButton.cancelAction = { [weak self] in self?.quickDecline() }\n        toolbarButton.calendarAction = { [weak self] in self?.openCalendarWorkspace() }\n        toolbarButton.start()\n''',
    "calendar toolbar action wiring",
)
s = must_replace(
    s,
    '''    private func openForwardWorkspace() {\n        requestedMailMode = .forward\n        replyAllForCurrentDraft = true\n        openWorkspace()\n    }\n\n    private func quickDecline() {\n''',
    '''    private func openForwardWorkspace() {\n        requestedMailMode = .forward\n        replyAllForCurrentDraft = true\n        openWorkspace()\n    }\n\n    private func openCalendarWorkspace() {\n        requestedMailMode = .calendar\n        replyAllForCurrentDraft = true\n        openWorkspace()\n    }\n\n    private func quickDecline() {\n''',
    "calendar workspace opener",
)
s = must_replace(
    s,
    '''        } else if requestedMailMode == .forward {\n            state.outputMode = .forward\n            state.instruction = ""\n        } else {\n''',
    '''        } else if requestedMailMode == .forward {\n            state.outputMode = .forward\n            state.instruction = ""\n        } else if requestedMailMode == .calendar {\n            state.outputMode = .calendar\n            state.instruction = ""\n        } else {\n''',
    "open calendar mode",
)
s = must_replace(
    s,
    '''                    } else if self.requestedMailMode == .forward {\n                        self.state.outputMode = .forward\n                    } else if self.requestedMailMode == .newMail {\n''',
    '''                    } else if self.requestedMailMode == .forward {\n                        self.state.outputMode = .forward\n                    } else if self.requestedMailMode == .calendar {\n                        self.state.outputMode = .calendar\n                    } else if self.requestedMailMode == .newMail {\n''',
    "refresh calendar mode",
)
old_forward = '''    private func forwardWithNote() {\n        let body = state.instruction.trimmingCharacters(in: .whitespacesAndNewlines)\n        guard !body.isEmpty else { return }\n        guard !state.mailText.isEmpty, activeSnapshot != nil else {\n            state.mailStatus = .unavailable("Keine lesbare Outlook-Mail erkannt. Für Forward bitte eine Mail öffnen und erneut versuchen.")\n            return\n        }\n\n        state.reply = body\n        state.replyHTML = state.instructionHTML\n        insertForwardDraft()\n    }\n'''
new_forward = '''    private func forwardWithNote() {\n        guard let apiKey = keychain.loadAPIKey() else {\n            state.stage = .apiKey\n            return\n        }\n\n        let instruction = state.instruction.trimmingCharacters(in: .whitespacesAndNewlines)\n        guard !instruction.isEmpty else { return }\n        guard !state.mailText.isEmpty, activeSnapshot != nil else {\n            state.mailStatus = .unavailable("Keine lesbare Outlook-Mail erkannt. Für Forward bitte eine Mail öffnen und erneut versuchen.")\n            return\n        }\n\n        isRunningFlow = true\n        toolbarButton.setSuppressed(true)\n        state.stage = .generating\n        state.statusText = "OpenAI formuliert den Forward Text"\n\n        openAI.generateForwardNote(\n            apiKey: apiKey,\n            mailText: state.mailText,\n            instruction: instruction,\n            instructionHTML: state.instructionHTML,\n            tone: state.replyTone,\n            language: state.replyLanguage,\n            compact: state.newMailCompact\n        ) { [weak self] result in\n            DispatchQueue.main.async {\n                guard let self else { return }\n                self.isRunningFlow = false\n\n                switch result {\n                case .success(let draft):\n                    self.state.reply = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)\n                    self.state.replyHTML = draft.html?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""\n                    self.insertForwardDraft()\n                case .failure(let error):\n                    self.showError(error.localizedDescription)\n                }\n            }\n        }\n    }\n'''
s = must_replace(s, old_forward, new_forward, "AI forward generation")
p.write_text(s)

# Version metadata.
p = root / "app" / "Info.plist"
s = p.read_text()
s = s.replace('<string>1.33.0</string>', '<string>1.34.0</string>', 1)
s = s.replace('<string>34</string>', '<string>35</string>', 1)
p.write_text(s)

p = root / "Build-CI.sh"
s = p.read_text()
s = s.replace('Replyzen-update-1.33.zip', 'Replyzen-update-1.34.zip')
s = s.replace(
    'Replyzen 1.33: Das Outlook Overlay sitzt tiefer und verdeckt die Outlook Suche nicht mehr. Forward öffnet jetzt zuerst Replyzen. Der dort eingegebene WYSIWYG Text wird unverändert oberhalb des nativen Outlook Forward Threads eingesetzt; Empfänger bleibt leer und Outlook behält ursprünglichen Thread und Anhänge.',
    'Replyzen 1.34: New, Reply und Forward verwenden dieselbe Mail Form mit WYSIWYG, Mood, Compact, Sprache und Reminder. Forward wird jetzt wie Reply/New Mail mit OpenAI formuliert und danach als nativer Outlook Forward ohne Empfänger eingesetzt; Thread und Anhänge bleiben erhalten. Termin wurde aus der Replyzen Hauptnavigation entfernt und ist nur noch als Termin Button hinter Cancel im Outlook Overlay verfügbar.'
)
p.write_text(s)
