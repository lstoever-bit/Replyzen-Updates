from pathlib import Path
import re
import sys

root = Path(sys.argv[1])


def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f"{label} not found")
    return text.replace(old, new, 1)

# AppState: keep rich HTML for the main mail input as well as the generated mail.
p = root / "app" / "AppState.swift"
s = p.read_text()
s = must_replace(
    s,
    '    @Published var instruction: String = ""\n    @Published var reply: String = ""\n',
    '    @Published var instruction: String = ""\n    @Published var instructionHTML: String = ""\n    @Published var reply: String = ""\n',
    "AppState instructionHTML",
)
p.write_text(s)

# RichTextMailEditor: make it reusable and compact enough for the main form.
p = root / "app" / "RichTextMailEditor.swift"
s = p.read_text()
s = must_replace(
    s,
    '''struct RichTextMailEditor: View {\n    @Binding var plainText: String\n    @Binding var html: String\n    @StateObject private var controller = RichTextEditorController()\n''',
    '''struct RichTextMailEditor: View {\n    @Binding var plainText: String\n    @Binding var html: String\n    var height: CGFloat = 176\n    var showsHTMLBadge: Bool = true\n    @StateObject private var controller = RichTextEditorController()\n''',
    "RichTextMailEditor configurable fields",
)
s = must_replace(
    s,
    '''                Spacer()\n                Text("HTML")\n                    .font(.system(size: 9, weight: .medium))\n                    .foregroundStyle(.tertiary)\n''',
    '''                Spacer()\n                if showsHTMLBadge {\n                    Text("HTML")\n                        .font(.system(size: 9, weight: .medium))\n                        .foregroundStyle(.tertiary)\n                }\n''',
    "RichTextMailEditor HTML badge",
)
s = must_replace(s, '        .frame(height: 176)\n', '        .frame(height: height)\n', "RichTextMailEditor height")
p.write_text(s)

# Overlay: the WYSIWYG editor belongs in the main Mail form, not a second preview screen.
p = root / "app" / "OverlayView.swift"
s = p.read_text()
old_editor = '''            } else {\n                TextEditor(text: $state.instruction)\n                    .font(.body)\n                    .frame(height: 122)\n                    .padding(8)\n                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))\n                    .overlay(alignment: .topLeading) {\n                        if state.instruction.isEmpty {\n                            Text(state.outputMode == .reply\n                                 ? "z. B. Sehr kurz, freundlich und direkt antworten."\n                                 : "z. B. Schreibe eine kurze Mail an Max und frage nach einem Termin nächste Woche.")\n                                .foregroundStyle(.tertiary)\n                                .padding(.leading, 14)\n                                .padding(.top, 16)\n                                .allowsHitTesting(false)\n                        }\n                    }\n            }\n'''
new_editor = '''            } else {\n                RichTextMailEditor(\n                    plainText: $state.instruction,\n                    html: $state.instructionHTML,\n                    height: 136,\n                    showsHTMLBadge: false\n                )\n            }\n'''
s = must_replace(s, old_editor, new_editor, "main WYSIWYG editor")

# Keep HTML state in sync when switching between Reply and New Mail.
s = must_replace(
    s,
    '''            if trimmed == "Kurz, freundlich und direkt antworten." ||\n               trimmed == "Reply briefly, friendly and directly." {\n                state.instruction = ""\n            }\n''',
    '''            if trimmed == "Kurz, freundlich und direkt antworten." ||\n               trimmed == "Reply briefly, friendly and directly." {\n                state.instruction = ""\n                state.instructionHTML = ""\n            }\n''',
    "clear main editor HTML on New Mail",
)
s = must_replace(
    s,
    '''            if state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {\n                state.instruction = state.replyLanguage == .german\n                    ? "Kurz, freundlich und direkt antworten."\n                    : "Reply briefly, friendly and directly."\n            }\n''',
    '''            if state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {\n                state.instruction = state.replyLanguage == .german\n                    ? "Kurz, freundlich und direkt antworten."\n                    : "Reply briefly, friendly and directly."\n                state.instructionHTML = ""\n            }\n''',
    "restore reply suggestion HTML",
)
p.write_text(s)

# OpenAIClient: return mail body plus safe email HTML so formatting can go straight to Outlook.
p = root / "app" / "OpenAIClient.swift"
s = p.read_text()
start = s.index('    func generateReply(\n')
end = s.index('    func generateQuickDecline(\n', start)
new_reply = '''    struct ReplyDraft: Decodable {\n        let body: String\n        let html: String?\n    }\n\n    func generateReply(\n        apiKey: String,\n        mailText: String,\n        instruction: String,\n        instructionHTML: String,\n        tone: ReplyTone,\n        language: AppState.ReplyLanguage,\n        compact: Bool,\n        completion: @escaping (Result<ReplyDraft, Error>) -> Void\n    ) {\n        var systemInstructions = [\n            "Draft an email reply for the user.",\n            "Return ONLY valid JSON with exactly these keys: body, html.",\n            "body: plain text version of the final reply.",\n            "html: the same final reply as a clean email safe HTML fragment. Use only p, br, strong, em, ul, ol and li. No CSS, script, html or body tags.",\n            "If the user's rich text instruction uses bold, italic, bullets or numbering as an intentional formatting cue, preserve that formatting in the final email where it makes sense.",\n            "Be concise, natural, and appropriate for email.",\n            tone.apiInstruction,\n            restrainedDashInstruction,\n            languageInstruction(for: language, purpose: "reply"),\n            "Follow the user's instruction precisely. The language of the instruction is never the output language unless it matches the selected output language.",\n            "Do not invent facts, promises, dates, attachments, or commitments.",\n            "Do not add a subject line.",\n            "Do not add a signature or the user's name."\n        ]\n        if compact {\n            systemInstructions.append("COMPACT MODE IS ON: make the reply as short as possible while preserving the requested meaning. Prefer 1 to 3 short sentences and normally stay under 70 words.")\n        }\n\n        let richInstruction = instructionHTML.trimmingCharacters(in: .whitespacesAndNewlines)\n        let input = "USER INSTRUCTION PLAIN:\\n\\(instruction)" +\n            (richInstruction.isEmpty ? "" : "\\n\\nUSER INSTRUCTION HTML FORMATTING CUES:\\n\\(richInstruction)") +\n            "\\n\\nEMAIL CONTENT:\\n\\(String(mailText.prefix(30_000)))"\n\n        performRequest(\n            apiKey: apiKey,\n            instructions: systemInstructions.joined(separator: "\\n"),\n            input: input,\n            maxOutputTokens: compact ? 340 : 700,\n            lowVerbosity: true\n        ) { result in\n            switch result {\n            case .success(let text):\n                do {\n                    completion(.success(try Self.decodeReplyDraft(text)))\n                } catch {\n                    completion(.failure(error))\n                }\n            case .failure(let error):\n                completion(.failure(error))\n            }\n        }\n    }\n\n'''
s = s[:start] + new_reply + s[end:]

s = must_replace(
    s,
    '''    struct NewMailDraft: Decodable {\n        let subject: String\n        let body: String\n    }\n''',
    '''    struct NewMailDraft: Decodable {\n        let subject: String\n        let body: String\n        let html: String?\n    }\n''',
    "NewMailDraft html",
)
s = must_replace(
    s,
    '''        apiKey: String,\n        instruction: String,\n        tone: ReplyTone,\n''',
    '''        apiKey: String,\n        instruction: String,\n        instructionHTML: String,\n        tone: ReplyTone,\n''',
    "generateNewMail instructionHTML parameter",
)
s = must_replace(
    s,
    '''            "Return ONLY valid JSON with exactly these keys: subject, body.",\n            "subject: write a short, useful email subject in the selected output language, ideally 2-7 words. Do not prefix it with Subject:, Betreff:, Re:, or Fwd:.",\n            "body: write the actual email body only. Do not repeat the subject in the body.",\n''',
    '''            "Return ONLY valid JSON with exactly these keys: subject, body, html.",\n            "subject: write a short, useful email subject in the selected output language, ideally 2-7 words. Do not prefix it with Subject:, Betreff:, Re:, or Fwd:.",\n            "body: write the actual email body only as plain text. Do not repeat the subject in the body.",\n            "html: the same final body as a clean email safe HTML fragment. Use only p, br, strong, em, ul, ol and li. No CSS, script, html or body tags.",\n            "If the user's rich text instruction uses bold, italic, bullets or numbering as an intentional formatting cue, preserve that formatting in the final email where it makes sense.",\n''',
    "New Mail HTML instructions",
)
s = must_replace(
    s,
    '''            "Follow the user's instruction precisely.",\n''',
    '''            "Follow the user's instruction precisely. The language of the instruction is never the output language unless it matches the selected output language.",\n''',
    "New Mail strict instruction language",
)
s = must_replace(
    s,
    '''            instructions: systemInstructions.joined(separator: "\\n"),\n            input: "USER INSTRUCTION:\\n\\(instruction)",\n            maxOutputTokens: compact ? 320 : 700,\n''',
    '''            instructions: systemInstructions.joined(separator: "\\n"),\n            input: "USER INSTRUCTION PLAIN:\\n\\(instruction)" +\n                (instructionHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty\n                    ? ""\n                    : "\\n\\nUSER INSTRUCTION HTML FORMATTING CUES:\\n\\(instructionHTML)"),\n            maxOutputTokens: compact ? 380 : 760,\n''',
    "New Mail rich input",
)

anchor = '    private static func decodeNewMailDraft(_ text: String) throws -> NewMailDraft {\n'
helper = '''    private static func decodeReplyDraft(_ text: String) throws -> ReplyDraft {\n        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)\n        if cleaned.hasPrefix("```") {\n            let lines = cleaned.split(separator: "\\n", omittingEmptySubsequences: false)\n            if lines.count >= 3 {\n                cleaned = lines.dropFirst().dropLast().joined(separator: "\\n")\n                if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("json") {\n                    cleaned = String(cleaned.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)\n                }\n            }\n        }\n        guard let data = cleaned.data(using: .utf8) else {\n            throw APIError(message: "OpenAI hat keinen gültigen Antwortentwurf geliefert.")\n        }\n        do {\n            let draft = try JSONDecoder().decode(ReplyDraft.self, from: data)\n            guard !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {\n                throw APIError(message: "OpenAI hat keinen Antworttext geliefert.")\n            }\n            return draft\n        } catch let error as APIError {\n            throw error\n        } catch {\n            throw APIError(message: "OpenAI hat den Antwortentwurf nicht im erwarteten Format geliefert.")\n        }\n    }\n\n'''
if anchor not in s:
    raise SystemExit("decodeNewMailDraft anchor not found")
s = s.replace(anchor, helper + anchor, 1)
p.write_text(s)

# AppDelegate: branded menu bar item, rich main input, and no intermediate mail preview.
p = root / "app" / "AppDelegate.swift"
s = p.read_text()
old_status = '''    private func configureStatusItem() {\n        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)\n        item.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Replyzen")\n\n        let menu = NSMenu()\n'''
new_status = '''    private func configureStatusItem() {\n        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)\n        if let url = Bundle.main.url(forResource: "ReplyzenLogo", withExtension: "png"),\n           let image = NSImage(contentsOf: url) {\n            image.size = NSSize(width: 16, height: 16)\n            item.button?.image = image\n        } else {\n            item.button?.image = NSImage(systemSymbolName: "envelope.badge", accessibilityDescription: "Replyzen")\n        }\n        item.button?.title = "Replyzen"\n        item.button?.imagePosition = .imageLeading\n        item.button?.font = .systemFont(ofSize: 13, weight: .semibold)\n        item.button?.toolTip = "Replyzen"\n\n        let menu = NSMenu()\n'''
s = must_replace(s, old_status, new_status, "menu bar branding")

s = must_replace(
    s,
    '''        state.outputMode = .reply\n        state.instruction = defaultReplyInstruction(for: state.replyLanguage)\n''',
    '''        state.outputMode = .reply\n        state.instruction = defaultReplyInstruction(for: state.replyLanguage)\n        state.instructionHTML = ""\n''',
    "openWorkspace rich input reset",
)

s = must_replace(
    s,
    '''                            self.state.instruction = self.defaultReplyInstruction(for: language)\n''',
    '''                            self.state.instruction = self.defaultReplyInstruction(for: language)\n                            self.state.instructionHTML = ""\n''',
    "language refresh rich input reset",
)

s = must_replace(
    s,
    '''            instruction: instruction,\n            tone: state.replyTone,\n''',
    '''            instruction: instruction,\n            instructionHTML: state.instructionHTML,\n            tone: state.replyTone,\n''',
    "generateReply rich input",
)

old_reply_success = '''                switch result {\n                case .success(let text):\n                    self.state.replyHTML = ""\n                    self.state.reply = text\n                    self.state.stage = .preview\n                    self.panel.show()\n                case .failure(let error):\n                    self.showError(error.localizedDescription)\n                }\n'''
new_reply_success = '''                switch result {\n                case .success(let draft):\n                    self.state.reply = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)\n                    self.state.replyHTML = draft.html?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""\n                    self.insertReply()\n                case .failure(let error):\n                    self.isRunningFlow = false\n                    self.showError(error.localizedDescription)\n                }\n'''
s = must_replace(s, old_reply_success, new_reply_success, "direct reply insertion")

# New Mail call and success path.
new_mail_call_marker = '''            apiKey: apiKey,\n            instruction: instruction,\n            tone: state.replyTone,\n            language: state.replyLanguage,\n            compact: state.newMailCompact\n'''
new_mail_call_replacement = '''            apiKey: apiKey,\n            instruction: instruction,\n            instructionHTML: state.instructionHTML,\n            tone: state.replyTone,\n            language: state.replyLanguage,\n            compact: state.newMailCompact\n'''
# The reply call has already been changed, so this exact block now belongs to New Mail.
s = must_replace(s, new_mail_call_marker, new_mail_call_replacement, "generateNewMail rich input")

old_new_success = '''                switch result {\n                case .success(let draft):\n                    self.state.newMailSubject = draft.subject.trimmingCharacters(in: .whitespacesAndNewlines)\n                    self.state.replyHTML = ""\n                    self.state.reply = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)\n                    self.state.stage = .preview\n                    self.panel.show()\n                case .failure(let error):\n                    self.showError(error.localizedDescription)\n                }\n'''
new_new_success = '''                switch result {\n                case .success(let draft):\n                    self.state.newMailSubject = draft.subject.trimmingCharacters(in: .whitespacesAndNewlines)\n                    self.state.reply = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)\n                    self.state.replyHTML = draft.html?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""\n                    self.insertNewMail()\n                case .failure(let error):\n                    self.isRunningFlow = false\n                    self.showError(error.localizedDescription)\n                }\n'''
s = must_replace(s, old_new_success, new_new_success, "direct new mail insertion")

# Rich pasteboard for replies, and after insertion stay in Outlook instead of reopening Replyzen.
s = must_replace(
    s,
    '''        copyToPasteboard(reply)\n        panel.hide()\n''',
    '''        copyMailToPasteboard(plainText: reply, html: state.replyHTML)\n        panel.hide()\n''',
    "reply rich pasteboard",
)
s = must_replace(
    s,
    '''                self.keyboard.sendCommandV()\n                self.isRunningFlow = false\n                self.state.stage = .success\n                self.panel.show()\n''',
    '''                self.keyboard.sendCommandV()\n                self.isRunningFlow = false\n                self.state.stage = .idle\n                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {\n                    self.toolbarButton.setSuppressed(false)\n                }\n''',
    "reply no success preview",
)
s = must_replace(
    s,
    '''    private func finishNewMailInsertion() {\n        isRunningFlow = false\n        state.successMessage = "Neue Outlook-Mail wurde mit Betreff und Mailtext vorbereitet."\n        state.stage = .success\n        panel.show()\n    }\n''',
    '''    private func finishNewMailInsertion() {\n        isRunningFlow = false\n        state.stage = .idle\n        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in\n            self?.toolbarButton.setSuppressed(false)\n        }\n    }\n''',
    "new mail no success preview",
)
p.write_text(s)

# Version and build.
p = root / "app" / "Info.plist"
s = p.read_text()
s = must_replace(s, "<string>1.27.0</string>", "<string>1.28.0</string>", "Info version")
s = must_replace(s, "<string>28</string>", "<string>29</string>", "Info build")
p.write_text(s)

# Build package and update notes.
p = root / "Build-CI.sh"
s = p.read_text()
s = s.replace("Replyzen-update-1.27.zip", "Replyzen-update-1.28.zip")
s = re.sub(
    r'"notes": ".*?"',
    '"notes": "Replyzen 1.28: Das Replyzen Logo und der Name erscheinen in der macOS Menüleiste. Der kompakte WYSIWYG Editor sitzt direkt in der Mail Hauptansicht. Nach Erstellen wird kein zweites Vorschaufenster mehr geöffnet, sondern Replyzen erzeugt die Mail und setzt sie direkt in Outlook ein. Fett, Kursiv und Listen werden als HTML/RTF an Outlook übergeben."',
    s,
    count=1,
)
p.write_text(s)
