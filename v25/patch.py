from pathlib import Path
import sys

root = Path(sys.argv[1])
app = root / 'app'


def replace(path: Path, old: str, new: str, count: int = 1):
    text = path.read_text()
    if old not in text:
        raise SystemExit(f'pattern not found in {path.name}: {old[:120]!r}')
    path.write_text(text.replace(old, new, count))

# 1) App state: New Mail gets its own Compact toggle.
p = app / 'AppState.swift'
replace(
    p,
    '    @Published var replyTone: ReplyTone = .friendly\n    @Published var selectedCommandName: String = "Custom"',
    '    @Published var replyTone: ReplyTone = .friendly\n    @Published var newMailCompact: Bool = false\n    @Published var selectedCommandName: String = "Custom"'
)

# 2) OpenAI client: New Mail mood + compact; Calendar language obeys selected flag strictly.
p = app / 'OpenAIClient.swift'
s = p.read_text()

old = '''    func generateNewMail(\n        apiKey: String,\n        instruction: String,\n        tone: ReplyTone,\n        language: AppState.ReplyLanguage,\n        completion: @escaping (Result<String, Error>) -> Void\n    ) {\n        let systemInstructions = [\n            "Draft a new email for the user based only on the user's instruction.",\n            "Be concise, natural, and appropriate for email.",\n            tone.apiInstruction,\n            languageInstruction(for: language, purpose: "email"),\n            "Follow the user's instruction precisely.",\n            "Do not invent facts, promises, dates, attachments, recipients, or commitments that the user did not provide.",\n            "Do not add a subject line unless the user explicitly asks for one.",\n            "Do not add a signature or the user's name unless the user explicitly asks for it.",\n            "Return only the email text."\n        ].joined(separator: "\\n")\n\n        performRequest(\n            apiKey: apiKey,\n            instructions: systemInstructions,\n            input: "USER INSTRUCTION:\\n\\(instruction)",\n            completion: completion\n        )\n    }'''
new = '''    func generateNewMail(\n        apiKey: String,\n        instruction: String,\n        tone: ReplyTone,\n        language: AppState.ReplyLanguage,\n        compact: Bool,\n        completion: @escaping (Result<String, Error>) -> Void\n    ) {\n        var systemInstructions = [\n            "Draft a new email for the user based only on the user's instruction.",\n            "Be concise, natural, and appropriate for email.",\n            tone.apiInstruction,\n            languageInstruction(for: language, purpose: "email"),\n            "Follow the user's instruction precisely.",\n            "Do not invent facts, promises, dates, attachments, recipients, or commitments that the user did not provide.",\n            "Do not add a subject line unless the user explicitly asks for one.",\n            "Do not add a signature or the user's name unless the user explicitly asks for it.",\n            "Return only the email text."\n        ]\n        if compact {\n            systemInstructions.append("COMPACT MODE IS ON: make the email as short as possible while preserving the requested meaning. Prefer 2-4 short sentences and normally stay under 80 words.")\n        }\n\n        performRequest(\n            apiKey: apiKey,\n            instructions: systemInstructions.joined(separator: "\\n"),\n            input: "USER INSTRUCTION:\\n\\(instruction)",\n            maxOutputTokens: compact ? 220 : nil,\n            lowVerbosity: compact,\n            completion: completion\n        )\n    }'''
if old not in s:
    raise SystemExit('generateNewMail block not found')
s = s.replace(old, new, 1)

old = '''        let titleLanguage = language == .german ? "German" : "US English"\n\n        let systemInstructions = ['''
new = '''        let titleLanguage = language == .german ? "German" : "US English"\n        let strictLanguageInstruction = language == .german\n            ? "OUTPUT LANGUAGE IS GERMAN. The title and description MUST be written in German, regardless of the language used in the email thread."\n            : "OUTPUT LANGUAGE IS US ENGLISH. The title and description MUST be written in natural US English, regardless of the language used in the email thread. Translate ordinary descriptive words; preserve only true proper names such as people, companies, products, and projects."\n\n        let systemInstructions = ['''
if old not in s:
    raise SystemExit('calendar language anchor not found')
s = s.replace(old, new, 1)

old = '            "Write title and description in \\(titleLanguage). Preserve important project or person names.",'
new = '            strictLanguageInstruction,\n            "Write title and description in \\(titleLanguage). Preserve important project or person names, but never copy the source language merely because the thread uses it.",'
if old not in s:
    raise SystemExit('calendar language instruction not found')
s = s.replace(old, new, 1)

old = '            input: "EMAIL THREAD:\\n\\(String(mailText.prefix(30_000)))",\n            model: "gpt-5.4-nano",'
new = '            input: "SELECTED OUTPUT LANGUAGE: \\(titleLanguage)\\n\\nEMAIL THREAD:\\n\\(String(mailText.prefix(30_000)))",\n            model: "gpt-5.4-nano",'
if old not in s:
    raise SystemExit('calendar input anchor not found')
s = s.replace(old, new, 1)
p.write_text(s)

# 3) AppDelegate: pass Compact to New Mail and brand all native Replyzen alerts.
p = app / 'AppDelegate.swift'
s = p.read_text()
old = '''        openAI.generateNewMail(\n            apiKey: apiKey,\n            instruction: instruction,\n            tone: state.replyTone,\n            language: state.replyLanguage\n        ) { [weak self] result in'''
new = '''        openAI.generateNewMail(\n            apiKey: apiKey,\n            instruction: instruction,\n            tone: state.replyTone,\n            language: state.replyLanguage,\n            compact: state.newMailCompact\n        ) { [weak self] result in'''
if old not in s:
    raise SystemExit('generateNewMail call not found')
s = s.replace(old, new, 1)

# Apply Replyzen icon to all NSAlert instances in this controller.
s = s.replace('''        let alert = NSAlert()\n        alert.messageText = "Update-Quelle"''', '''        let alert = NSAlert()\n        brandAlert(alert)\n        alert.messageText = "Replyzen · Update-Quelle"''', 1)
s = s.replace('''        let alert = NSAlert()\n        alert.messageText = "Replyzen \\(update.manifest.version) ist verfügbar"''', '''        let alert = NSAlert()\n        brandAlert(alert)\n        alert.messageText = "Replyzen \\(update.manifest.version) ist verfügbar"''', 1)

old = '''    private func showSimpleAlert(title: String, message: String) {\n        let alert = NSAlert()\n        alert.messageText = title\n        alert.informativeText = message\n        alert.addButton(withTitle: "OK")\n        NSApp.activate(ignoringOtherApps: true)\n        alert.runModal()\n    }'''
new = '''    private func showSimpleAlert(title: String, message: String) {\n        let alert = NSAlert()\n        brandAlert(alert)\n        alert.messageText = title == "Replyzen" ? "Replyzen" : "Replyzen · \\(title)"\n        alert.informativeText = message\n        alert.addButton(withTitle: "OK")\n        NSApp.activate(ignoringOtherApps: true)\n        alert.runModal()\n    }\n\n    private func brandAlert(_ alert: NSAlert) {\n        if let url = Bundle.main.url(forResource: "ReplyzenLogo", withExtension: "png"),\n           let image = NSImage(contentsOf: url) {\n            image.size = NSSize(width: 64, height: 64)\n            alert.icon = image\n        } else {\n            alert.icon = NSApp.applicationIconImage\n        }\n    }'''
if old not in s:
    raise SystemExit('showSimpleAlert block not found')
s = s.replace(old, new, 1)
p.write_text(s)

# 4) Overlay UI: Commands only in Reply. New Mail uses Mood + Compact.
p = app / 'OverlayView.swift'
s = p.read_text()
old = '''            HStack(spacing: 8) {\n                if state.outputMode != .calendar {\n                    Menu {\n                        ForEach(commands.commands) { command in\n                            Button(command.name) {\n                                applyCommand(command)\n                            }\n                        }\n\n                        Divider()\n\n                        Button("+ Add Command…") {\n                            showCommandManager = true\n                        }\n                        Button("Manage Commands…") {\n                            showCommandManager = true\n                        }\n                    } label: {\n                        HStack(spacing: 5) {\n                            Image(systemName: "slider.horizontal.3")\n                            Text("Commands")\n                        }\n                    }\n                    .controlSize(.small)\n                    .help("Eigene Replyzen-Befehle auswählen oder verwalten")\n                }\n\n                Spacer()'''
new = '''            HStack(spacing: 10) {\n                if state.outputMode == .reply {\n                    Menu {\n                        ForEach(commands.commands) { command in\n                            Button(command.name) {\n                                applyCommand(command)\n                            }\n                        }\n\n                        Divider()\n\n                        Button("+ Add Command…") {\n                            showCommandManager = true\n                        }\n                        Button("Manage Commands…") {\n                            showCommandManager = true\n                        }\n                    } label: {\n                        HStack(spacing: 5) {\n                            Image(systemName: "slider.horizontal.3")\n                            Text("Commands")\n                        }\n                    }\n                    .controlSize(.small)\n                    .help("Eigene Replyzen-Befehle auswählen oder verwalten")\n                } else if state.outputMode == .newMail {\n                    HStack(spacing: 7) {\n                        Text("Mood")\n                            .font(.caption)\n                            .foregroundStyle(.secondary)\n                        Picker("Mood", selection: $state.replyTone) {\n                            ForEach(ReplyTone.allCases) { tone in\n                                Text(tone.displayName).tag(tone)\n                            }\n                        }\n                        .labelsHidden()\n                        .pickerStyle(.menu)\n                        .frame(minWidth: 130)\n\n                        Toggle("Compact", isOn: $state.newMailCompact)\n                            .toggleStyle(.checkbox)\n                            .help("Erstellt eine möglichst kurze Mail")\n                    }\n                }\n\n                Spacer()'''
if old not in s:
    raise SystemExit('commands menu block not found')
s = s.replace(old, new, 1)

old = '''            if state.outputMode != .calendar {\n                HStack(spacing: 6) {\n                    Text("Command: \\(state.selectedCommandName)")\n                    Text("·")\n                    Text("Tone: \\(state.replyTone.displayName)")\n                    Text("·")\n                    Text("Sprache: \\(state.replyLanguage.displayName)")\n                }\n                .font(.caption)\n                .foregroundStyle(.secondary)\n            } else {\n                Text("Sprache: \\(state.replyLanguage.displayName)")\n                    .font(.caption)\n                    .foregroundStyle(.secondary)\n            }'''
new = '''            if state.outputMode == .reply {\n                HStack(spacing: 6) {\n                    Text("Command: \\(state.selectedCommandName)")\n                    Text("·")\n                    Text("Tone: \\(state.replyTone.displayName)")\n                    Text("·")\n                    Text("Sprache: \\(state.replyLanguage.displayName)")\n                }\n                .font(.caption)\n                .foregroundStyle(.secondary)\n            } else if state.outputMode == .newMail {\n                HStack(spacing: 6) {\n                    Text("Mood: \\(state.replyTone.displayName)")\n                    Text("·")\n                    Text(state.newMailCompact ? "Compact" : "Normal")\n                    Text("·")\n                    Text("Sprache: \\(state.replyLanguage.displayName)")\n                }\n                .font(.caption)\n                .foregroundStyle(.secondary)\n            } else {\n                Text("Sprache: \\(state.replyLanguage.displayName)")\n                    .font(.caption)\n                    .foregroundStyle(.secondary)\n            }'''
if old not in s:
    raise SystemExit('status metadata block not found')
s = s.replace(old, new, 1)
p.write_text(s)

# 5) Version bump to 1.15 / build 16.
p = app / 'Info.plist'
s = p.read_text()
s = s.replace('<string>1.14.0</string>', '<string>1.15.0</string>', 1)
s = s.replace('<string>15</string>', '<string>16</string>', 1)
p.write_text(s)

# 6) Update package metadata.
p = root / 'Build-CI.sh'
s = p.read_text()
s = s.replace('Replyzen-update-1.14.zip', 'Replyzen-update-1.15.zip')
s = s.replace(
    'Replyzen 1.14: schnellere Terminextraktion mit einem kleinen Extraction-Modell; Replyzen schwebt nur im Outlook-Kontext und verschwindet bei Wechsel zu anderen Apps.',
    'Replyzen 1.15: Termintitel und -text folgen strikt der gewählten Sprache; New Mail hat Mood plus Compact statt Commands; native Dialoge verwenden Replyzen-Name und Replyzen-Logo.'
)
p.write_text(s)
