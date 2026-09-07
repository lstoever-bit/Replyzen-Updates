from pathlib import Path
import re
import sys

root = Path(sys.argv[1])

def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f"{label} not found")
    return text.replace(old, new, 1)

# AppDelegate: open the unified Mail form in New Mail while Outlook context is
# being checked. If a readable mail is found, switch the same form to Reply,
# detect its language, and select the built-in reply suggestion. If no mail is
# found, stay in New Mail without showing a dead Reply option.
p = root / "app" / "AppDelegate.swift"
s = p.read_text()

old_open = '''        // Replyzen opens the unified Mail workspace in Reply mode. There are no
        // reply presets or saved commands anymore. A single lightweight default
        // instruction is selected so typing replaces it immediately.
        state.outputMode = .reply
        state.instruction = defaultReplyInstruction(for: state.replyLanguage)
'''
new_open = '''        // Replyzen has one unified Mail form. While Outlook context is being
        // checked it starts as New Mail. If a readable message is found below,
        // the same form switches to Reply automatically.
        state.outputMode = .newMail
        state.instruction = ""
'''
s = must_replace(s, old_open, new_open, "openWorkspace unified mail")

old_show = '''        state.stage = .instruction
        panel.show(activate: true)
        panel.selectInstructionTextSoon()

        refreshMailContext()
'''
new_show = '''        state.stage = .instruction
        panel.show(activate: true)

        refreshMailContext()
'''
s = must_replace(s, old_show, new_show, "openWorkspace initial selection")

old_success = '''                    // Language selection is instant and local; it does not spend
                    // another API request. We currently expose German and US English
                    // in the UI, so only switch when one of those is confidently
                    // recognized.
                    if self.state.outputMode == .reply,
                       let language = self.detectReplyLanguage(in: mail) {
                        let currentInstruction = self.state.instruction
                        self.state.replyLanguage = language
                        if self.isDefaultReplyInstruction(currentInstruction) {
                            self.state.instruction = self.defaultReplyInstruction(for: language)
                        }
                    }

                    // Keep the built in suggestion fully selected after the mail
                    // context arrives, so the first keystroke replaces it.
                    if self.state.outputMode == .reply {
                        self.panel.selectInstructionTextSoon()
                    }
'''
new_success = '''                    // A readable message means Reply becomes available in the
                    // same Mail form. Select it automatically unless the user has
                    // already started writing a New Mail instruction while loading.
                    if self.state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.state.outputMode = .reply
                    }

                    // Language selection is instant and local; it does not spend
                    // another API request.
                    if let language = self.detectReplyLanguage(in: mail) {
                        self.state.replyLanguage = language
                    }

                    if self.state.outputMode == .reply {
                        if self.state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                           self.isDefaultReplyInstruction(self.state.instruction) {
                            self.state.instruction = self.defaultReplyInstruction(for: self.state.replyLanguage)
                        }
                        // The lightweight suggestion is selected so typing replaces
                        // it immediately.
                        self.panel.selectInstructionTextSoon()
                    }
'''
s = must_replace(s, old_success, new_success, "mail success unified form")

old_catch_tail = '''                    self.state.mailStatus = .unavailable(message)
                }
            }
        }
    }
'''
new_catch_tail = '''                    self.state.mailStatus = .unavailable(message)
                    // No mail context means Reply is not a valid action. Keep the
                    // same form in New Mail and remove only the built-in reply hint.
                    self.state.outputMode = .newMail
                    if self.isDefaultReplyInstruction(self.state.instruction) {
                        self.state.instruction = ""
                    }
                }
            }
        }
    }
'''
s = must_replace(s, old_catch_tail, new_catch_tail, "mail failure new mail fallback")

old_trust = '''        guard outlook.isTrusted() else {
            state.mailStatus = .unavailable("Outlook-Zugriff ist noch nicht freigegeben. New Mail funktioniert trotzdem.")
            outlook.requestTrustPrompt()
            return
        }
'''
new_trust = '''        guard outlook.isTrusted() else {
            state.outputMode = .newMail
            state.mailStatus = .unavailable("Keine Outlook-Mail verfügbar. Reply ist ausgeblendet.")
            outlook.requestTrustPrompt()
            return
        }
'''
s = must_replace(s, old_trust, new_trust, "trust fallback")
p.write_text(s)

# Overlay: one visual Mail form. Reply/New Mail is only a compact behavior
# switch inside that form. Hide Reply completely when no Outlook mail is
# available and show only a small status hint. Remove the heading above the
# instruction box.
p = root / "app" / "OverlayView.swift"
s = p.read_text()
s = s.replace('Text("Reply, New Mail, Termin oder Überweisung – direkt aus Outlook.")',
              'Text("Mail, Termin oder Überweisung, direkt aus Outlook.")')

old_context = '''            if state.outputMode == .reply || state.outputMode == .newMail {
                mailTypeSelector
            }

            if state.outputMode != .newMail {
                mailContextBanner
            }
'''
new_context = '''            if state.outputMode == .reply || state.outputMode == .newMail {
                mailTypeSelector
            } else {
                mailContextBanner
            }
'''
s = must_replace(s, old_context, new_context, "mail context layout")

old_editor = '''            } else {
                Text(state.outputMode == .reply ? "Was soll ich antworten?" : "Was soll ich schreiben?")
                    .font(.title3.bold())

                TextEditor(text: $state.instruction)
                    .font(.body)
                    .frame(height: 122)
                    .padding(8)
                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topLeading) {
                        if state.instruction.isEmpty {
                            Text(state.outputMode == .reply
                                 ? "z. B. Sehr kurz, freundlich und direkt antworten."
                                 : "z. B. Schreibe eine kurze Mail an Max und frage nach einem Termin nächste Woche.")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 14)
                                .padding(.top, 16)
                                .allowsHitTesting(false)
                        }
                    }
            }
'''
new_editor = '''            } else {
                TextEditor(text: $state.instruction)
                    .font(.body)
                    .frame(height: 122)
                    .padding(8)
                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topLeading) {
                        if state.instruction.isEmpty {
                            Text(state.outputMode == .reply
                                 ? "z. B. Sehr kurz, freundlich und direkt antworten."
                                 : "z. B. Schreibe eine kurze Mail an Max und frage nach einem Termin nächste Woche.")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 14)
                                .padding(.top, 16)
                                .allowsHitTesting(false)
                        }
                    }
            }
'''
s = must_replace(s, old_editor, new_editor, "remove mail form heading")

# Replace segmented picker with a compact inline switch that conditionally
# exposes Reply. This keeps a single form and does not reserve empty space for a
# mode that cannot work.
pattern = re.compile(r'''    private var mailTypeSelector: some View \{.*?\n    \}\n\n    private func modeButton''', re.S)
replacement = '''    private var mailTypeSelector: some View {
        HStack(spacing: 8) {
            if mailAvailable {
                mailTypeButton(.reply, title: "Reply", systemImage: "arrowshape.turn.up.left.fill")
            }
            mailTypeButton(.newMail, title: "New Mail", systemImage: "square.and.pencil")

            if !mailAvailable {
                HStack(spacing: 5) {
                    if case .loading = state.mailStatus {
                        ProgressView().controlSize(.mini)
                        Text("Prüfe Outlook-Mail …")
                    } else {
                        Image(systemName: "info.circle")
                        Text("Keine Mail erkannt. Reply ist ausgeblendet.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            }

            Spacer(minLength: 0)
        }
    }

    private func mailTypeButton(_ mode: AppState.OutputMode, title: String, systemImage: String) -> some View {
        Button {
            guard state.outputMode != mode else { return }
            state.outputMode = mode
            handleModeChange(mode)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(state.outputMode == mode ? .accentColor : .gray.opacity(0.32))
        .controlSize(.small)
    }

    private func modeButton'''
s2, n = pattern.subn(replacement, s, count=1)
if n != 1:
    raise SystemExit("mailTypeSelector block not replaced")
s = s2

old_handle = '''    private func handleModeChange(_ mode: AppState.OutputMode) {
        switch mode {
        case .newMail:
            state.instruction = ""
            state.newMailSubject = ""
        case .reply:
            if state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state.instruction = state.replyLanguage == .german
                    ? "Kurz, freundlich und direkt antworten."
                    : "Reply briefly, friendly and directly."
            }
        case .calendar, .payment:
            break
        }
    }
'''
new_handle = '''    private func handleModeChange(_ mode: AppState.OutputMode) {
        switch mode {
        case .newMail:
            // Same form, same user input. Only remove Replyzen's own built-in
            // reply suggestion if it is still untouched.
            let trimmed = state.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "Kurz, freundlich und direkt antworten." ||
               trimmed == "Reply briefly, friendly and directly." {
                state.instruction = ""
            }
            state.newMailSubject = ""
        case .reply:
            if state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state.instruction = state.replyLanguage == .german
                    ? "Kurz, freundlich und direkt antworten."
                    : "Reply briefly, friendly and directly."
            }
        case .calendar, .payment:
            break
        }
    }
'''
s = must_replace(s, old_handle, new_handle, "same mail form mode change")
p.write_text(s)

# Version + build.
p = root / "app" / "Info.plist"
s = p.read_text()
s = must_replace(s, "<string>1.24.0</string>", "<string>1.25.0</string>", "Info version")
s = must_replace(s, "<string>25</string>", "<string>26</string>", "Info build")
p.write_text(s)

# Build script package and notes.
p = root / "Build-CI.sh"
s = p.read_text()
s = s.replace("Replyzen-update-1.24.zip", "Replyzen-update-1.25.zip")
s = re.sub(
    r'"notes": ".*?"',
    '"notes": "Replyzen 1.25: Mail ist jetzt wirklich eine einzige Form. Reply und New Mail schalten nur das Verhalten derselben Eingabemaske um. Die Überschrift über dem Textfeld ist entfernt. Wenn keine Outlook-Mail erkannt wird, ist Reply ausgeblendet und es erscheint nur ein kleiner Hinweis."',
    s,
    count=1,
)
p.write_text(s)
