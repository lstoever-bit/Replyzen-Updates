from pathlib import Path
import re
import sys

root = Path(sys.argv[1])


def replace1(text, old, new, label):
    if old not in text:
        raise SystemExit(f"{label} not found")
    return text.replace(old, new, 1)

# AppState: rich HTML for the main mail input.
p = root / "app" / "AppState.swift"
s = p.read_text()
s = replace1(
    s,
    '    @Published var instruction: String = ""\n    @Published var reply: String = ""\n',
    '    @Published var instruction: String = ""\n    @Published var instructionHTML: String = ""\n    @Published var reply: String = ""\n',
    "AppState instructionHTML",
)
p.write_text(s)

# Reuse the rich editor in the main form and keep it compact.
p = root / "app" / "RichTextMailEditor.swift"
s = p.read_text()
s = replace1(
    s,
    '''struct RichTextMailEditor: View {\n    @Binding var plainText: String\n    @Binding var html: String\n    @StateObject private var controller = RichTextEditorController()\n''',
    '''struct RichTextMailEditor: View {\n    @Binding var plainText: String\n    @Binding var html: String\n    var height: CGFloat = 176\n    var showsHTMLBadge: Bool = true\n    @StateObject private var controller = RichTextEditorController()\n''',
    "RichText editor options",
)
s = replace1(
    s,
    '''                Spacer()\n                Text("HTML")\n                    .font(.system(size: 9, weight: .medium))\n                    .foregroundStyle(.tertiary)\n''',
    '''                Spacer()\n                if showsHTMLBadge {\n                    Text("HTML")\n                        .font(.system(size: 9, weight: .medium))\n                        .foregroundStyle(.tertiary)\n                }\n''',
    "RichText HTML badge",
)
s = replace1(s, '        .frame(height: 176)\n', '        .frame(height: height)\n', "RichText editor height")
p.write_text(s)

# Main Replyzen view: WYSIWYG editor is the actual mail input area.
p = root / "app" / "OverlayView.swift"
s = p.read_text()
old_editor = '''            } else {\n                TextEditor(text: $state.instruction)\n                    .font(.body)\n                    .frame(height: 122)\n                    .padding(8)\n                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))\n                    .overlay(alignment: .topLeading) {\n                        if state.instruction.isEmpty {\n                            Text(state.outputMode == .reply\n                                 ? "z. B. Sehr kurz, freundlich und direkt antworten."\n                                 : "z. B. Schreibe eine kurze Mail an Max und frage nach einem Termin nächste Woche.")\n                                .foregroundStyle(.tertiary)\n                                .padding(.leading, 14)\n                                .padding(.top, 16)\n                                .allowsHitTesting(false)\n                        }\n                    }\n            }\n'''
new_editor = '''            } else {\n                RichTextMailEditor(\n                    plainText: $state.instruction,\n                    html: $state.instructionHTML,\n                    height: 136,\n                    showsHTMLBadge: false\n                )\n            }\n'''
s = replace1(s, old_editor, new_editor, "main WYSIWYG editor")
s = replace1(
    s,
    '''            if trimmed == "Kurz, freundlich und direkt antworten." ||\n               trimmed == "Reply briefly, friendly and directly." {\n                state.instruction = ""\n            }\n''',
    '''            if trimmed == "Kurz, freundlich und direkt antworten." ||\n               trimmed == "Reply briefly, friendly and directly." {\n                state.instruction = ""\n                state.instructionHTML = ""\n            }\n''',
    "clear main rich input for New",
)
s = replace1(
    s,
    '''            if state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {\n                state.instruction = state.replyLanguage == .german\n                    ? "Kurz, freundlich und direkt antworten."\n                    : "Reply briefly, friendly and directly."\n            }\n''',
    '''            if state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {\n                state.instruction = state.replyLanguage == .german\n                    ? "Kurz, freundlich und direkt antworten."\n                    : "Reply briefly, friendly and directly."\n                state.instructionHTML = ""\n            }\n''',
    "reset main rich input for Reply",
)
p.write_text(s)

# OpenAI: return both plain text and safe HTML for mail drafts.
p = root / "app" / "OpenAIClient.swift"
s = p.read_text()
reply_start = s.index('    func generateReply(\n')
reply_end = s.index('    func generateQuickDecline(\n', reply_start)
new_reply = '''    struct ReplyDraft: Decodable {\n        let body: String\n        let html: String?\n    }\n\n    func generateReply(\n        apiKey: String,\n        mailText: String,\n        instruction: String,\n        instructionHTML: String,\n        tone: ReplyTone,\n        language: AppState.ReplyLanguage,\n        compact: Bool,\n        completion: @escaping (Result<ReplyDraft, Error>) -> Void\n    ) {\n        var systemInstructions = [\n            "Draft an email reply for the user.",\n            "Return ONLY valid JSON with exactly these keys: body, html.",\n            "body is the plain text final reply.",\n            "html is the same final reply as a clean email safe HTML fragment. Use only p, br, strong, em, ul, ol and li. Do not use CSS, script, html or body tags.",\n            "If the user's rich text instruction intentionally uses bold, italic, bullets or numbering, preserve that formatting in the final email where it makes sense.",\n            "Be concise, natural, and appropriate for email.",\n            tone.apiInstruction,\n            restrainedDashInstruction,\n            languageInstruction(for: language, purpose: "reply"),\n            "Follow the user's instruction precisely. The language of the instruction is input only and must never override the selected output language.",\n            "Do not invent facts, promises, dates, attachments, or commitments.",\n            "Do not add a subject line.",\n            "Do not add a signature or the user's name."\n        ]\n        if compact {\n            systemInstructions.append("COMPACT MODE IS ON: make the reply as short as possible while preserving the requested meaning. Prefer 1 to 3 short sentences and normally stay under 70 words.")\n        }\n\n        let richInstruction = instructionHTML.trimmingCharacters(in: .whitespacesAndNewlines)\n        let input = "USER INSTRUCTION PLAIN:\\n\\(instruction)" +\n            (richInstruction.isEmpty ? "" : "\\n\\nUSER INSTRUCTION HTML FORMATTING CUES:\\n\\(richInstruction)") +\n            "\\n\\nEMAIL CONTENT:\\n\\(String(mailText.prefix(30_000)))"\n\n        performRequest(\n            apiKey: apiKey,\n            instructions: systemInstructions.joined(separator: "\\n"),\n            input: input,\n            maxOutputTokens: compact ? 340 : 700,\n            lowVerbosity: true\n        ) { result in\n            switch result {\n            case .success(let text):\n                do { completion(.success(try Self.decodeReplyDraft(text))) }\n                catch { completion(.failure(error)) }\n            case .failure(let error):\n                completion(.failure(error))\n            }\n        }\n    }\n\n'''
s = s[:reply_start] + new_reply + s[reply_end:]

newmail_start = s.index('    struct NewMailDraft: Decodable {')
newmail_end = s.index('    private var restrainedDashInstruction: String {', newmail_start)
new_newmail = '''    struct NewMailDraft: Decodable {\n        let subject: String\n        let body: String\n        let html: String?\n    }\n\n    func generateNewMail(\n        apiKey: String,\n        instruction: String,\n        instructionHTML: String,\n        tone: ReplyTone,\n        language: AppState.ReplyLanguage,\n        compact: Bool,\n        completion: @escaping (Result<NewMailDraft, Error>) -> Void\n    ) {\n        var systemInstructions = [\n            "Draft a new email for the user based only on the user's instruction.",\n            "Return ONLY valid JSON with exactly these keys: subject, body, html.",\n            "subject: write a short useful email subject in the selected output language, ideally 2 to 7 words. Do not prefix it with Subject, Betreff, Re or Fwd.",\n            "body: write the actual email body only as plain text. Do not repeat the subject in the body.",\n            "html: the same final body as a clean email safe HTML fragment. Use only p, br, strong, em, ul, ol and li. Do not use CSS, script, html or body tags.",\n            "If the user's rich text instruction intentionally uses bold, italic, bullets or numbering, preserve that formatting in the final email where it makes sense.",\n            "Be concise, natural, and appropriate for email.",\n            tone.apiInstruction,\n            languageInstruction(for: language, purpose: "email subject and body"),\n            restrainedDashInstruction,\n            "Follow the user's instruction precisely. The language of the instruction is input only and must never override the selected output language.",\n            "Do not invent facts, promises, dates, attachments, recipients, or commitments that the user did not provide.",\n            "Do not add a signature or the user's name unless the user explicitly asks for it."\n        ]\n        if compact {\n            systemInstructions.append("COMPACT MODE IS ON: make the body as short as possible while preserving the requested meaning. Prefer 2 to 4 short sentences and normally stay under 80 words.")\n        }\n\n        let richInstruction = instructionHTML.trimmingCharacters(in: .whitespacesAndNewlines)\n        let input = "USER INSTRUCTION PLAIN:\\n\\(instruction)" +\n            (richInstruction.isEmpty ? "" : "\\n\\nUSER INSTRUCTION HTML FORMATTING CUES:\\n\\(richInstruction)")\n\n        performRequest(\n            apiKey: apiKey,\n            instructions: systemInstructions.joined(separator: "\\n"),\n            input: input,\n            maxOutputTokens: compact ? 380 : 760,\n            lowVerbosity: true\n        ) { result in\n            switch result {\n            case .success(let text):\n                do { completion(.success(try Self.decodeNewMailDraft(text))) }\n                catch { completion(.failure(error)) }\n            case .failure(let error):\n                completion(.failure(error))\n            }\n        }\n    }\n\n'''
s = s[:newmail_start] + new_newmail + s[newmail_end:]

anchor = '    private static func decodeNewMailDraft(_ text: String) throws -> NewMailDraft {\n'
reply_decoder = '''    private static func decodeReplyDraft(_ text: String) throws -> ReplyDraft {\n        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)\n        if cleaned.hasPrefix("```") {\n            let lines = cleaned.split(separator: "\\n", omittingEmptySubsequences: false)\n            if lines.count >= 3 {\n                cleaned = lines.dropFirst().dropLast().joined(separator: "\\n")\n                if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("json") {\n                    cleaned = String(cleaned.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)\n                }\n            }\n        }\n        guard let data = cleaned.data(using: .utf8) else {\n            throw APIError(message: "OpenAI hat keinen gültigen Antwortentwurf geliefert.")\n        }\n        do {\n            let draft = try JSONDecoder().decode(ReplyDraft.self, from: data)\n            guard !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {\n                throw APIError(message: "OpenAI hat keinen Antworttext geliefert.")\n            }\n            return draft\n        } catch let error as APIError {\n            throw error\n        } catch {\n            throw APIError(message: "OpenAI hat den Antwortentwurf nicht im erwarteten Format geliefert.")\n        }\n    }\n\n'''
if anchor not in s:
    raise SystemExit("reply decoder anchor not found")
s = s.replace(anchor, reply_decoder + anchor, 1)
p.write_text(s)

# Outlook overlay: exactly New, Reply, Decline.
p = root / "app" / "OutlookToolbarButtonController.swift"
p.write_text('''import AppKit\nimport ApplicationServices\n\nfinal class OutlookToolbarButtonController: NSObject {\n    private let outlook: OutlookAccessibility\n    private let panel: NSPanel\n    private let newButton: NSButton\n    private let replyButton: NSButton\n    private let declineButton: NSButton\n    private var timer: Timer?\n    private var isSuppressed = false\n\n    var newAction: (() -> Void)?\n    var replyAction: (() -> Void)?\n    var declineAction: (() -> Void)?\n\n    init(outlook: OutlookAccessibility) {\n        self.outlook = outlook\n\n        let size = NSSize(width: 250, height: 34)\n        panel = NSPanel(\n            contentRect: NSRect(origin: .zero, size: size),\n            styleMask: [.borderless, .nonactivatingPanel],\n            backing: .buffered,\n            defer: false\n        )\n\n        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))\n        effect.material = .hudWindow\n        effect.blendingMode = .withinWindow\n        effect.state = .active\n        effect.wantsLayer = true\n        effect.layer?.cornerRadius = 9\n        effect.layer?.masksToBounds = true\n\n        func makeButton(title: String, symbol: String, x: CGFloat, width: CGFloat, help: String) -> NSButton {\n            let button = NSButton(frame: NSRect(x: x, y: 3, width: width, height: 28))\n            button.title = title\n            button.bezelStyle = .rounded\n            button.font = .systemFont(ofSize: 12.5, weight: .semibold)\n            button.alignment = .center\n            button.isBordered = false\n            button.setButtonType(.momentaryPushIn)\n            button.toolTip = help\n            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)\n            button.imagePosition = .imageLeading\n            button.imageScaling = .scaleProportionallyDown\n            return button\n        }\n\n        newButton = makeButton(title: "New", symbol: "square.and.pencil", x: 4, width: 72, help: "Neue Mail mit Replyzen")\n        replyButton = makeButton(title: "Reply", symbol: "arrowshape.turn.up.left.fill", x: 84, width: 76, help: "Auf die aktuelle Mail antworten")\n        declineButton = makeButton(title: "Decline", symbol: "xmark.circle", x: 168, width: 78, help: "Freundliche kurze Absage direkt als Antwort einsetzen")\n\n        effect.addSubview(newButton)\n        effect.addSubview(replyButton)\n        effect.addSubview(declineButton)\n\n        panel.contentView = effect\n        panel.isOpaque = false\n        panel.backgroundColor = .clear\n        panel.hasShadow = true\n        panel.hidesOnDeactivate = false\n        panel.level = .floating\n        panel.isMovable = false\n        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]\n        panel.becomesKeyOnlyIfNeeded = true\n\n        super.init()\n\n        newButton.target = self\n        newButton.action = #selector(newClicked)\n        replyButton.target = self\n        replyButton.action = #selector(replyClicked)\n        declineButton.target = self\n        declineButton.action = #selector(declineClicked)\n    }\n\n    func start() {\n        timer?.invalidate()\n        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in self?.update() }\n        RunLoop.main.add(timer!, forMode: .common)\n        update()\n    }\n\n    func stop() {\n        timer?.invalidate()\n        timer = nil\n        panel.orderOut(nil)\n    }\n\n    func setSuppressed(_ suppressed: Bool) {\n        isSuppressed = suppressed\n        if suppressed { panel.orderOut(nil) } else { update() }\n    }\n\n    @objc private func newClicked() { newAction?() }\n    @objc private func replyClicked() { replyAction?() }\n    @objc private func declineClicked() { declineAction?() }\n\n    private func update() {\n        guard !isSuppressed,\n              outlook.isTrusted(),\n              let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.microsoft.Outlook" }),\n              running.isActive,\n              let frame = outlook.focusedWindowFrameInAppKitCoordinates() else {\n            panel.orderOut(nil)\n            return\n        }\n\n        let size = panel.frame.size\n        let x = frame.maxX - size.width - 122\n        let y = frame.maxY - size.height - 10\n        panel.setFrameOrigin(NSPoint(x: x, y: y))\n        panel.orderFrontRegardless()\n    }\n}\n''')

# AppDelegate: menu bar branding, explicit New/Reply actions, direct insertion with no second preview.
p = root / "app" / "AppDelegate.swift"
s = p.read_text()
s = replace1(
    s,
    '    private var updateMenuItem: NSMenuItem?\n',
    '    private var updateMenuItem: NSMenuItem?\n    private var requestedMailMode: AppState.OutputMode?\n',
    "requested mail mode property",
)
old_status = '''    private func configureStatusItem() {\n        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)\n        item.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Replyzen")\n\n        let menu = NSMenu()\n'''
new_status = '''    private func configureStatusItem() {\n        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)\n        if let url = Bundle.main.url(forResource: "ReplyzenLogo", withExtension: "png"),\n           let image = NSImage(contentsOf: url) {\n            image.size = NSSize(width: 16, height: 16)\n            item.button?.image = image\n        } else {\n            item.button?.image = NSImage(systemSymbolName: "envelope.badge", accessibilityDescription: "Replyzen")\n        }\n        item.button?.title = "Replyzen"\n        item.button?.imagePosition = .imageLeading\n        item.button?.font = .systemFont(ofSize: 13, weight: .semibold)\n        item.button?.toolTip = "Replyzen"\n\n        let menu = NSMenu()\n'''
s = replace1(s, old_status, new_status, "menu bar Replyzen branding")
old_toolbar = '''    private func configureToolbarButton() {\n        toolbarButton.action = { [weak self] in self?.openWorkspace() }\n        toolbarButton.declineAction = { [weak self] in self?.quickDecline() }\n        toolbarButton.start()\n    }\n'''
new_toolbar = '''    private func configureToolbarButton() {\n        toolbarButton.newAction = { [weak self] in self?.openNewMailWorkspace() }\n        toolbarButton.replyAction = { [weak self] in self?.openReplyWorkspace() }\n        toolbarButton.declineAction = { [weak self] in self?.quickDecline() }\n        toolbarButton.start()\n    }\n\n    private func openNewMailWorkspace() {\n        requestedMailMode = .newMail\n        openWorkspace()\n    }\n\n    private func openReplyWorkspace() {\n        requestedMailMode = .reply\n        openWorkspace()\n    }\n'''
s = replace1(s, old_toolbar, new_toolbar, "toolbar actions")

old_open_init = '''        // Replyzen has one unified Mail form. While Outlook context is being\n        // checked it starts as New Mail. If a readable message is found below,\n        // the same form switches to Reply automatically.\n        state.outputMode = .newMail\n        state.instruction = ""\n'''
new_open_init = '''        // One unified Mail form. New and Reply only choose the behavior of the\n        // same form. The Outlook overlay can request either mode explicitly.\n        if requestedMailMode == .reply {\n            state.outputMode = .reply\n            state.instruction = defaultReplyInstruction(for: state.replyLanguage)\n        } else {\n            state.outputMode = .newMail\n            state.instruction = ""\n        }\n        state.instructionHTML = ""\n'''
s = replace1(s, old_open_init, new_open_init, "openWorkspace initialization")

old_success_mode = '''                    // A readable message means Reply becomes available in the\n                    // same Mail form. Select it automatically unless the user has\n                    // already started writing a New Mail instruction while loading.\n                    if self.state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {\n                        self.state.outputMode = .reply\n                    }\n'''
new_success_mode = '''                    // Respect an explicit New or Reply click from the Outlook overlay.\n                    if self.requestedMailMode == .reply {\n                        self.state.outputMode = .reply\n                    } else if self.requestedMailMode == .newMail {\n                        self.state.outputMode = .newMail\n                    } else if self.state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {\n                        self.state.outputMode = .reply\n                    }\n'''
s = replace1(s, old_success_mode, new_success_mode, "mail mode after context load")

s = replace1(
    s,
    '''                            self.state.instruction = self.defaultReplyInstruction(for: self.state.replyLanguage)\n''',
    '''                            self.state.instruction = self.defaultReplyInstruction(for: self.state.replyLanguage)\n                            self.state.instructionHTML = ""\n''',
    "reply instruction HTML reset",
)
# Clear requested mode after success and failure context resolution.
s = replace1(
    s,
    '''                        self.panel.selectInstructionTextSoon()\n                    }\n                }\n''',
    '''                        self.panel.selectInstructionTextSoon()\n                    }\n                    self.requestedMailMode = nil\n                }\n''',
    "clear requested mode success",
)
s = replace1(
    s,
    '''                    if self.isDefaultReplyInstruction(self.state.instruction) {\n                        self.state.instruction = ""\n                    }\n''',
    '''                    if self.isDefaultReplyInstruction(self.state.instruction) {\n                        self.state.instruction = ""\n                        self.state.instructionHTML = ""\n                    }\n                    self.requestedMailMode = nil\n''',
    "clear requested mode failure",
)

# Pass rich input to OpenAI.
s = replace1(
    s,
    '''            instruction: instruction,\n            tone: state.replyTone,\n            language: state.replyLanguage,\n            compact: state.newMailCompact\n''',
    '''            instruction: instruction,\n            instructionHTML: state.instructionHTML,\n            tone: state.replyTone,\n            language: state.replyLanguage,\n            compact: state.newMailCompact\n''',
    "reply rich input call",
)
# The next matching call is New Mail.
s = replace1(
    s,
    '''            instruction: instruction,\n            tone: state.replyTone,\n            language: state.replyLanguage,\n            compact: state.newMailCompact\n''',
    '''            instruction: instruction,\n            instructionHTML: state.instructionHTML,\n            tone: state.replyTone,\n            language: state.replyLanguage,\n            compact: state.newMailCompact\n''',
    "new mail rich input call",
)

old_reply_result = '''                switch result {\n                case .success(let text):\n                    self.state.replyHTML = ""\n                    self.state.reply = text\n                    self.state.stage = .preview\n                    self.panel.show()\n                case .failure(let error):\n                    self.showError(error.localizedDescription)\n                }\n'''
new_reply_result = '''                switch result {\n                case .success(let draft):\n                    self.state.reply = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)\n                    self.state.replyHTML = draft.html?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""\n                    self.insertReply()\n                case .failure(let error):\n                    self.showError(error.localizedDescription)\n                }\n'''
s = replace1(s, old_reply_result, new_reply_result, "direct Reply insertion")
old_new_result = '''                switch result {\n                case .success(let draft):\n                    self.state.newMailSubject = draft.subject.trimmingCharacters(in: .whitespacesAndNewlines)\n                    self.state.replyHTML = ""\n                    self.state.reply = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)\n                    self.state.stage = .preview\n                    self.panel.show()\n                case .failure(let error):\n                    self.showError(error.localizedDescription)\n                }\n'''
new_new_result = '''                switch result {\n                case .success(let draft):\n                    self.state.newMailSubject = draft.subject.trimmingCharacters(in: .whitespacesAndNewlines)\n                    self.state.reply = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)\n                    self.state.replyHTML = draft.html?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""\n                    self.insertNewMail()\n                case .failure(let error):\n                    self.showError(error.localizedDescription)\n                }\n'''
s = replace1(s, old_new_result, new_new_result, "direct New insertion")

# Rich reply paste and stay in Outlook after insertion. No second Replyzen preview or success screen.
s = replace1(s, '        copyToPasteboard(reply)\n        panel.hide()\n', '        copyMailToPasteboard(plainText: reply, html: state.replyHTML)\n        panel.hide()\n', "rich reply pasteboard")
s = replace1(
    s,
    '''                self.keyboard.sendCommandV()\n                self.isRunningFlow = false\n                self.state.stage = .success\n                self.panel.show()\n''',
    '''                self.keyboard.sendCommandV()\n                self.isRunningFlow = false\n                self.state.stage = .idle\n                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {\n                    self.toolbarButton.setSuppressed(false)\n                }\n''',
    "reply stay in Outlook",
)
s = replace1(
    s,
    '''    private func finishNewMailInsertion() {\n        isRunningFlow = false\n        state.successMessage = "Neue Outlook-Mail wurde mit Betreff und Mailtext vorbereitet."\n        state.stage = .success\n        panel.show()\n    }\n''',
    '''    private func finishNewMailInsertion() {\n        isRunningFlow = false\n        state.stage = .idle\n        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in\n            self?.toolbarButton.setSuppressed(false)\n        }\n    }\n''',
    "new mail stay in Outlook",
)
# Decline must never reuse stale rich HTML from another draft.
s = s.replace('        copyMailToPasteboard(plainText: reply, html: state.replyHTML)\n        panel.hide()\n        outlook.activateOutlook(pid: snapshot.pid)\n', '        copyToPasteboard(reply)\n        panel.hide()\n        outlook.activateOutlook(pid: snapshot.pid)\n', 1)
p.write_text(s)

# Version/build and update package.
p = root / "app" / "Info.plist"
s = p.read_text()
s = replace1(s, '<string>1.27.0</string>', '<string>1.28.0</string>', "version")
s = replace1(s, '<string>28</string>', '<string>29</string>', "build")
p.write_text(s)

p = root / "Build-CI.sh"
s = p.read_text()
s = s.replace('Replyzen-update-1.27.zip', 'Replyzen-update-1.28.zip')
s = re.sub(
    r'"notes": ".*?"',
    '"notes": "Replyzen 1.28: Das Outlook Overlay hat jetzt genau New, Reply und Decline. Das Replyzen Logo plus Name erscheinen in der macOS Menüleiste. Der kompakte WYSIWYG Editor sitzt direkt in der Mail Hauptansicht. Nach Erstellen wird kein zweites Vorschaufenster geöffnet, sondern die Mail wird direkt in Outlook vorbereitet. Fett, Kursiv und Listen werden als HTML und RTF an Outlook übergeben."',
    s,
    count=1,
)
p.write_text(s)
