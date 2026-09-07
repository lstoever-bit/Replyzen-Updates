from pathlib import Path
import re
import sys

root = Path(sys.argv[1])


def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f"{label} not found")
    return text.replace(old, new, 1)

# ---------------- AppDelegate ----------------
p = root / "app" / "AppDelegate.swift"
s = p.read_text()

s = must_replace(
    s,
    "    private let state = AppState()\n    private let commandStore = CommandStore()\n    private lazy var panel = FloatingPanelController(state: state, commands: commandStore)\n",
    "    private let state = AppState()\n    private lazy var panel = FloatingPanelController(state: state)\n",
    "remove command store runtime",
)

old_open = '''        // The main Replyzen overlay is the normal reply workflow. If another\n        // mode was used previously, switch back to Reply and restore its default\n        // suggested command. The suggestion is selected below so the user can\n        // overwrite it by simply typing.\n        let wasReplyMode = state.outputMode == .reply\n        state.outputMode = .reply\n        if !wasReplyMode {\n            state.instruction = \"\"\n            state.selectedCommandName = \"Custom\"\n        }\n\n'''
new_open = '''        // Replyzen opens the unified Mail workspace in Reply mode. There are no\n        // reply presets or saved commands anymore. A single lightweight default\n        // instruction is selected so typing replaces it immediately.\n        state.outputMode = .reply\n        state.instruction = defaultReplyInstruction(for: state.replyLanguage)\n\n'''
s = must_replace(s, old_open, new_open, "openWorkspace unified mail")

s = must_replace(
    s,
    "        toolbarButton.setSuppressed(true)\n        prepareDefaultCommandIfNeeded()\n        state.stage = .instruction\n",
    "        toolbarButton.setSuppressed(true)\n        state.stage = .instruction\n",
    "remove command preparation",
)

old_lang = '''                    if self.state.outputMode == .reply,\n                       let language = self.detectReplyLanguage(in: mail) {\n                        self.state.replyLanguage = language\n                    }\n\n                    // Keep the suggested instruction fully selected after the mail\n                    // context arrives, so the first keystroke replaces it.\n                    if self.state.outputMode == .reply {\n                        self.panel.selectInstructionTextSoon()\n                    }\n'''
new_lang = '''                    if self.state.outputMode == .reply,\n                       let language = self.detectReplyLanguage(in: mail) {\n                        let currentInstruction = self.state.instruction\n                        self.state.replyLanguage = language\n                        if self.isDefaultReplyInstruction(currentInstruction) {\n                            self.state.instruction = self.defaultReplyInstruction(for: language)\n                        }\n                    }\n\n                    // Keep the built in suggestion fully selected after the mail\n                    // context arrives, so the first keystroke replaces it.\n                    if self.state.outputMode == .reply {\n                        self.panel.selectInstructionTextSoon()\n                    }\n'''
s = must_replace(s, old_lang, new_lang, "language aware default instruction")

start = s.find("    private func prepareDefaultCommandIfNeeded() {")
end = s.find("    private func refreshMailContext() {", start)
if start == -1 or end == -1:
    raise SystemExit("prepareDefaultCommandIfNeeded block not found")
helpers = '''    private func defaultReplyInstruction(for language: AppState.ReplyLanguage) -> String {\n        switch language {\n        case .german:\n            return \"Kurz, freundlich und direkt antworten.\"\n        case .usEnglish:\n            return \"Reply briefly, friendly and directly.\"\n        }\n    }\n\n    private func isDefaultReplyInstruction(_ text: String) -> Bool {\n        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)\n        return cleaned == defaultReplyInstruction(for: .german) ||\n               cleaned == defaultReplyInstruction(for: .usEnglish)\n    }\n\n'''
s = s[:start] + helpers + s[end:]

s = must_replace(
    s,
    "            tone: state.replyTone,\n            language: state.replyLanguage\n",
    "            tone: state.replyTone,\n            language: state.replyLanguage,\n            compact: state.newMailCompact\n",
    "reply compact argument",
)

p.write_text(s)

# ---------------- Floating panel ----------------
p = root / "app" / "FloatingPanelController.swift"
s = p.read_text()
s = must_replace(
    s,
    "    init(state: AppState, commands: CommandStore) {",
    "    init(state: AppState) {",
    "panel init signature",
)
s = must_replace(
    s,
    "        let host = NSHostingController(rootView: OverlayView(state: state, commands: commands))",
    "        let host = NSHostingController(rootView: OverlayView(state: state))",
    "overlay init",
)
p.write_text(s)

# ---------------- Overlay UI ----------------
p = root / "app" / "OverlayView.swift"
s = p.read_text()

s = must_replace(
    s,
    "    @ObservedObject var state: AppState\n    @ObservedObject var commands: CommandStore\n    @State private var showCommandManager = false\n",
    "    @ObservedObject var state: AppState\n",
    "remove command properties",
)
s = must_replace(
    s,
    '''        .frame(minWidth: 590, minHeight: 390)\n        .sheet(isPresented: $showCommandManager) {\n            CommandManagerView(store: commands)\n        }\n''',
    '''        .frame(minWidth: 590, minHeight: 390)\n''',
    "remove command sheet",
)

s = must_replace(
    s,
    '''            modeSelector\n\n            if state.outputMode != .newMail {\n                mailContextBanner\n            }\n''',
    '''            modeSelector\n\n            if state.outputMode == .reply || state.outputMode == .newMail {\n                mailTypeSelector\n            }\n\n            if state.outputMode != .newMail {\n                mailContextBanner\n            }\n''',
    "mail type selector placement",
)

old_controls = '''            HStack(spacing: 10) {\n                if state.outputMode == .reply {\n                    Menu {\n                        ForEach(commands.commands) { command in\n                            Button(command.name) {\n                                applyCommand(command)\n                            }\n                        }\n\n                        Divider()\n\n                        Button(\"+ Add Command…\") {\n                            showCommandManager = true\n                        }\n                        Button(\"Manage Commands…\") {\n                            showCommandManager = true\n                        }\n                    } label: {\n                        HStack(spacing: 5) {\n                            Image(systemName: \"slider.horizontal.3\")\n                            Text(\"Commands\")\n                        }\n                    }\n                    .controlSize(.small)\n                    .help(\"Eigene Replyzen-Befehle auswählen oder verwalten\")\n                } else if state.outputMode == .newMail {\n                    HStack(spacing: 7) {\n                        Text(\"Mood\")\n                            .font(.caption)\n                            .foregroundStyle(.secondary)\n                        Picker(\"Mood\", selection: $state.replyTone) {\n                            ForEach(ReplyTone.allCases) { tone in\n                                Text(tone.displayName).tag(tone)\n                            }\n                        }\n                        .labelsHidden()\n                        .pickerStyle(.menu)\n                        .frame(minWidth: 130)\n\n                        Toggle(\"Compact\", isOn: $state.newMailCompact)\n                            .toggleStyle(.checkbox)\n                            .help(\"Erstellt eine möglichst kurze Mail\")\n                    }\n                }\n\n                Spacer()\n\n                if state.outputMode != .payment {\n                    languageButton(\"🇩🇪\", language: .german, help: \"Ausgabe auf Deutsch\")\n                    languageButton(\"🇺🇸\", language: .usEnglish, help: \"Ausgabe in US English\")\n                }\n            }\n'''
new_controls = '''            HStack(spacing: 10) {\n                if state.outputMode == .reply || state.outputMode == .newMail {\n                    HStack(spacing: 7) {\n                        Text(\"Mood\")\n                            .font(.caption)\n                            .foregroundStyle(.secondary)\n                        Picker(\"Mood\", selection: $state.replyTone) {\n                            ForEach(ReplyTone.allCases) { tone in\n                                Text(tone.displayName).tag(tone)\n                            }\n                        }\n                        .labelsHidden()\n                        .pickerStyle(.menu)\n                        .frame(minWidth: 130)\n\n                        Toggle(\"Compact\", isOn: $state.newMailCompact)\n                            .toggleStyle(.checkbox)\n                            .help(\"Erstellt eine möglichst kurze Mail\")\n                    }\n                }\n\n                Spacer()\n\n                if state.outputMode != .payment {\n                    languageButton(\"🇩🇪\", language: .german, help: \"Ausgabe auf Deutsch\")\n                    languageButton(\"🇺🇸\", language: .usEnglish, help: \"Ausgabe in US English\")\n                }\n            }\n'''
s = must_replace(s, old_controls, new_controls, "remove commands and keep mood compact")

old_status = '''            if state.outputMode == .reply {\n                HStack(spacing: 6) {\n                    Text(\"Command: \\(state.selectedCommandName)\")\n                    Text(\"·\")\n                    Text(\"Tone: \\(state.replyTone.displayName)\")\n                    Text(\"·\")\n                    Text(\"Sprache: \\(state.replyLanguage.displayName)\")\n                }\n                .font(.caption)\n                .foregroundStyle(.secondary)\n            } else if state.outputMode == .newMail {\n                HStack(spacing: 6) {\n                    Text(\"Mood: \\(state.replyTone.displayName)\")\n                    Text(\"·\")\n                    Text(state.newMailCompact ? \"Compact\" : \"Normal\")\n                    Text(\"·\")\n                    Text(\"Sprache: \\(state.replyLanguage.displayName)\")\n                }\n                .font(.caption)\n                .foregroundStyle(.secondary)\n'''
new_status = '''            if state.outputMode == .reply || state.outputMode == .newMail {\n                HStack(spacing: 6) {\n                    Text(\"Mood: \\(state.replyTone.displayName)\")\n                    Text(\"·\")\n                    Text(state.newMailCompact ? \"Compact\" : \"Normal\")\n                    Text(\"·\")\n                    Text(\"Sprache: \\(state.replyLanguage.displayName)\")\n                }\n                .font(.caption)\n                .foregroundStyle(.secondary)\n'''
s = must_replace(s, old_status, new_status, "unified mail status")

old_selector = '''    private var modeSelector: some View {\n        HStack(spacing: 8) {\n            modeButton(.reply, title: \"Reply\", systemImage: \"arrowshape.turn.up.left.fill\")\n            modeButton(.newMail, title: \"New Mail\", systemImage: \"square.and.pencil\")\n            modeButton(.calendar, title: \"Termin\", systemImage: \"calendar.badge.plus\")\n            modeButton(.payment, title: \"Überweisung\", systemImage: \"banknote\")\n        }\n    }\n\n'''
new_selector = '''    private var modeSelector: some View {\n        HStack(spacing: 8) {\n            modeButton(.reply, title: \"Mail\", systemImage: \"envelope.fill\")\n            modeButton(.calendar, title: \"Termin\", systemImage: \"calendar.badge.plus\")\n            modeButton(.payment, title: \"Überweisung\", systemImage: \"banknote\")\n        }\n    }\n\n    private var mailTypeSelector: some View {\n        Picker(\"Mailtyp\", selection: Binding(\n            get: { state.outputMode },\n            set: { mode in\n                guard mode == .reply || mode == .newMail else { return }\n                guard state.outputMode != mode else { return }\n                state.outputMode = mode\n                handleModeChange(mode)\n            }\n        )) {\n            Label(\"Reply\", systemImage: \"arrowshape.turn.up.left.fill\").tag(AppState.OutputMode.reply)\n            Label(\"New Mail\", systemImage: \"square.and.pencil\").tag(AppState.OutputMode.newMail)\n        }\n        .pickerStyle(.segmented)\n        .labelsHidden()\n    }\n\n'''
s = must_replace(s, old_selector, new_selector, "unified top selector")

s = must_replace(
    s,
    "        .tint(state.outputMode == mode ? .accentColor : .gray.opacity(0.32))",
    "        .tint(isTopLevelModeSelected(mode) ? .accentColor : .gray.opacity(0.32))",
    "top selector tint",
)

anchor = '''    @ViewBuilder\n    private var mailContextBanner: some View {\n'''
helper = '''    private func isTopLevelModeSelected(_ mode: AppState.OutputMode) -> Bool {\n        if mode == .reply {\n            return state.outputMode == .reply || state.outputMode == .newMail\n        }\n        return state.outputMode == mode\n    }\n\n'''
if anchor not in s:
    raise SystemExit("mailContextBanner anchor not found")
s = s.replace(anchor, helper + anchor, 1)

old_handle = '''    private func handleModeChange(_ mode: AppState.OutputMode) {\n        switch mode {\n        case .newMail:\n            state.instruction = \"\"\n            state.selectedCommandName = \"Custom\"\n            state.replyTone = .professional\n            state.newMailSubject = \"\"\n        case .reply:\n            if state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,\n               let first = commands.commands.first {\n                applyCommand(first)\n            }\n        case .calendar, .payment:\n            break\n        }\n    }\n\n    private func applyCommand(_ command: ReplyCommand) {\n        state.selectedCommandName = command.name\n        state.instruction = command.prompt\n        state.replyTone = command.tone\n    }\n\n'''
new_handle = '''    private func handleModeChange(_ mode: AppState.OutputMode) {\n        switch mode {\n        case .newMail:\n            state.instruction = \"\"\n            state.newMailSubject = \"\"\n        case .reply:\n            if state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {\n                state.instruction = state.replyLanguage == .german\n                    ? \"Kurz, freundlich und direkt antworten.\"\n                    : \"Reply briefly, friendly and directly.\"\n            }\n        case .calendar, .payment:\n            break\n        }\n    }\n\n'''
s = must_replace(s, old_handle, new_handle, "remove command mode logic")

p.write_text(s)

# ---------------- OpenAI client ----------------
p = root / "app" / "OpenAIClient.swift"
s = p.read_text()

start = s.find("    func generateReply(\n")
end = s.find("    func generateQuickDecline(\n", start)
if start == -1 or end == -1:
    raise SystemExit("generateReply block not found")
new_reply = '''    func generateReply(\n        apiKey: String,\n        mailText: String,\n        instruction: String,\n        tone: ReplyTone,\n        language: AppState.ReplyLanguage,\n        compact: Bool,\n        completion: @escaping (Result<String, Error>) -> Void\n    ) {\n        var systemInstructions = [\n            \"Draft an email reply for the user.\",\n            \"Be concise, natural, and appropriate for email.\",\n            tone.apiInstruction,\n            languageInstruction(for: language, purpose: \"reply\"),\n            restrainedDashInstruction,\n            \"Follow the user's instruction precisely.\",\n            \"Do not invent facts, promises, dates, attachments, or commitments.\",\n            \"Do not add a subject line.\",\n            \"Do not add a signature or the user's name.\",\n            \"Return only the reply text.\"\n        ]\n        if compact {\n            systemInstructions.append(\"COMPACT MODE IS ON: make the reply as short as possible while preserving the requested meaning. Prefer 1 to 3 short sentences and normally stay under 70 words.\")\n        }\n\n        performRequest(\n            apiKey: apiKey,\n            instructions: systemInstructions.joined(separator: \"\\n\"),\n            input: \"USER INSTRUCTION:\\n\\(instruction)\\n\\nEMAIL CONTENT:\\n\\(String(mailText.prefix(30_000)))\",\n            maxOutputTokens: compact ? 260 : 520,\n            lowVerbosity: true,\n            completion: completion\n        )\n    }\n\n'''
s = s[:start] + new_reply + s[end:]

# Add the restrained punctuation rule to all generative prose flows. Payment extraction
# remains exact and is intentionally untouched.
s = must_replace(
    s,
    '            "Keep it warm, polite and concise: normally 1-3 short sentences.",\n',
    '            "Keep it warm, polite and concise: normally 1-3 short sentences.",\n            restrainedDashInstruction,\n',
    "quick decline dash rule",
)
s = must_replace(
    s,
    '            "Be concise, natural, and appropriate for email.",\n            tone.apiInstruction,\n',
    '            "Be concise, natural, and appropriate for email.",\n            tone.apiInstruction,\n            restrainedDashInstruction,\n',
    "new mail dash rule",
)
s = must_replace(
    s,
    '            "Be concise, clear, and structured.",\n',
    '            "Be concise, clear, and structured.",\n            restrainedDashInstruction,\n',
    "summary dash rule",
)
s = must_replace(
    s,
    '            strictLanguageInstruction,\n            "Write title and description in \\(titleLanguage). Preserve important project or person names, but never copy the source language merely because the thread uses it.",\n',
    '            strictLanguageInstruction,\n            restrainedDashInstruction,\n            "Write title and description in \\(titleLanguage). Preserve important project or person names, but never copy the source language merely because the thread uses it.",\n',
    "calendar dash rule",
)

# Add shared style instruction before first decoder helper.
anchor = '''    private static func decodeNewMailDraft(_ text: String) throws -> NewMailDraft {\n'''
style = '''    private var restrainedDashInstruction: String {\n        \"Avoid hyphens, en dashes, and em dashes in normal prose. Use them only when absolutely necessary for correctness or when preserving exact source text such as names, dates, URLs, email addresses, or reference numbers. Prefer commas, periods, or separate sentences instead.\"\n    }\n\n'''
if anchor not in s:
    raise SystemExit("decodeNewMailDraft anchor not found")
s = s.replace(anchor, style + anchor, 1)
p.write_text(s)

# ---------------- Version ----------------
p = root / "app" / "Info.plist"
s = p.read_text()
s = must_replace(s, "<string>1.23.0</string>", "<string>1.24.0</string>", "Info version")
s = must_replace(s, "<string>24</string>", "<string>25</string>", "Info build")
p.write_text(s)

# ---------------- Build script ----------------
p = root / "Build-CI.sh"
s = p.read_text()
s = s.replace("Replyzen-update-1.23.zip", "Replyzen-update-1.24.zip")
s = re.sub(
    r'"notes": ".*?"',
    '"notes": "Replyzen 1.24: Reply und New Mail sind in einem Mail Bereich zusammengefasst und werden über einen Schalter gewählt. Die komplette Commands Logik ist entfernt. Mood und Compact gelten für beide Mail Modi. Generierte Texte vermeiden Bindestriche und Gedankenstriche, außer wenn sie wirklich nötig sind."',
    s,
    count=1,
)
p.write_text(s)
