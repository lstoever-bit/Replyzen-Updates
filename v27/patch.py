from pathlib import Path
import sys

root = Path(sys.argv[1])

# 1) App state: store a dedicated New Mail subject.
p = root / 'app' / 'AppState.swift'
s = p.read_text()
anchor = '    @Published var newMailCompact: Bool = false\n'
if anchor not in s:
    raise SystemExit('AppState newMailCompact anchor not found')
s = s.replace(anchor, anchor + '    @Published var newMailSubject: String = ""\n', 1)
p.write_text(s)

# 2) OpenAI: New Mail must always return a separate subject + body.
p = root / 'app' / 'OpenAIClient.swift'
s = p.read_text()
start = s.index('    func generateNewMail(')
end = s.index('    func summarizeThread(', start)
new_block = r'''    struct NewMailDraft: Decodable {
        let subject: String
        let body: String
    }

    func generateNewMail(
        apiKey: String,
        instruction: String,
        tone: ReplyTone,
        language: AppState.ReplyLanguage,
        compact: Bool,
        completion: @escaping (Result<NewMailDraft, Error>) -> Void
    ) {
        var systemInstructions = [
            "Draft a new email for the user based only on the user's instruction.",
            "Return ONLY valid JSON with exactly these keys: subject, body.",
            "subject: write a short, useful email subject in the selected output language, ideally 2-7 words. Do not prefix it with Subject:, Betreff:, Re:, or Fwd:.",
            "body: write the actual email body only. Do not repeat the subject in the body.",
            "Be concise, natural, and appropriate for email.",
            tone.apiInstruction,
            languageInstruction(for: language, purpose: "email subject and body"),
            "Follow the user's instruction precisely.",
            "Do not invent facts, promises, dates, attachments, recipients, or commitments that the user did not provide.",
            "Do not add a signature or the user's name unless the user explicitly asks for it."
        ]
        if compact {
            systemInstructions.append("COMPACT MODE IS ON: make the body as short as possible while preserving the requested meaning. Prefer 2-4 short sentences and normally stay under 80 words.")
        }

        performRequest(
            apiKey: apiKey,
            instructions: systemInstructions.joined(separator: "\n"),
            input: "USER INSTRUCTION:\n\(instruction)",
            maxOutputTokens: compact ? 320 : 700,
            lowVerbosity: compact
        ) { result in
            switch result {
            case .success(let text):
                do {
                    completion(.success(try Self.decodeNewMailDraft(text)))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private static func decodeNewMailDraft(_ text: String) throws -> NewMailDraft {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count >= 3 {
                cleaned = lines.dropFirst().dropLast().joined(separator: "\n")
                if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("json") {
                    cleaned = String(cleaned.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        guard let data = cleaned.data(using: .utf8) else {
            throw APIError(message: "OpenAI hat keinen gültigen Mailentwurf geliefert.")
        }
        do {
            let draft = try JSONDecoder().decode(NewMailDraft.self, from: data)
            guard !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw APIError(message: "OpenAI hat keinen Mailtext geliefert.")
            }
            return draft
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError(message: "OpenAI hat den Mailentwurf nicht im erwarteten Format geliefert.")
        }
    }

'''
s = s[:start] + new_block + s[end:]
p.write_text(s)

# 3) AppDelegate: store subject and reliably populate Outlook compose fields.
p = root / 'app' / 'AppDelegate.swift'
s = p.read_text()
old_success = '''                switch result {\n                case .success(let text):\n                    self.state.reply = text\n                    self.state.stage = .preview\n                    self.panel.show()\n                case .failure(let error):\n                    self.showError(error.localizedDescription)\n                }\n'''
# There are two identical success blocks; replace only the one inside generateNewMail by locating the function.
fn_start = s.index('    private func generateNewMail()')
fn_end = s.index('    private func generateCalendarSuggestion()', fn_start)
segment = s[fn_start:fn_end]
if old_success not in segment:
    raise SystemExit('generateNewMail success block not found')
segment = segment.replace(old_success, '''                switch result {\n                case .success(let draft):\n                    self.state.newMailSubject = draft.subject.trimmingCharacters(in: .whitespacesAndNewlines)\n                    self.state.reply = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)\n                    self.state.stage = .preview\n                    self.panel.show()\n                case .failure(let error):\n                    self.showError(error.localizedDescription)\n                }\n''', 1)
s = s[:fn_start] + segment + s[fn_end:]

old_insert_start = s.index('    private func insertNewMail() {')
old_insert_end = s.index('    private func copyToPasteboard(', old_insert_start)
new_insert = r'''    private func insertNewMail() {
        let subject = state.newMailSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = state.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        guard let pid = outlook.runningPID() else {
            copyToPasteboard(body)
            showError("Microsoft Outlook läuft nicht. Der Mailtext wurde in die Zwischenablage kopiert.")
            return
        }

        guard outlook.isTrusted() else {
            copyToPasteboard(body)
            outlook.requestTrustPrompt()
            showError("Replyzen braucht Bedienungshilfen, um automatisch eine neue Outlook-Mail zu befüllen. Der Mailtext wurde in die Zwischenablage kopiert.")
            return
        }

        state.stage = .inserting
        state.statusText = "Neue Outlook-Mail wird geöffnet und befüllt"
        isRunningFlow = true
        toolbarButton.setSuppressed(true)

        panel.hide()
        outlook.activateOutlook(pid: pid)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.keyboard.sendCommandN()
            self?.populateNewMailDraft(subject: subject, body: body, attempt: 0)
        }
    }

    private func populateNewMailDraft(subject: String, body: String, attempt: Int) {
        let delay = attempt == 0 ? 0.85 : 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }

            let subjectDone = subject.isEmpty || self.outlook.setComposeSubjectValue(subject)
            let bodyDone = self.outlook.setComposeBodyValue(body)

            if subjectDone && bodyDone {
                self.finishNewMailInsertion()
                return
            }

            if attempt < 8 {
                self.populateNewMailDraft(subject: subject, body: body, attempt: attempt + 1)
                return
            }

            // Fallback for Outlook builds where the web editor is focusable but AXValue is not directly settable.
            var subjectReady = subjectDone
            if !subjectReady, self.outlook.focusComposeSubjectField() {
                self.copyToPasteboard(subject)
                self.keyboard.sendCommandV()
                subjectReady = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self else { return }
                if self.outlook.focusComposeBodyField() {
                    self.copyToPasteboard(body)
                    self.keyboard.sendCommandV()
                    self.finishNewMailInsertion()
                } else {
                    self.copyToPasteboard(body)
                    self.isRunningFlow = false
                    let subjectInfo = subjectReady ? "Der Betreff wurde eingesetzt. " : ""
                    self.showError("\(subjectInfo)Der Outlook-Mailtext konnte nicht automatisch fokussiert werden. Der Mailtext liegt in der Zwischenablage.")
                }
            }
        }
    }

    private func finishNewMailInsertion() {
        isRunningFlow = false
        state.successMessage = "Neue Outlook-Mail wurde mit Betreff und Mailtext vorbereitet."
        state.stage = .success
        panel.show()
    }

'''
s = s[:old_insert_start] + new_insert + s[old_insert_end:]
p.write_text(s)

# 4) Outlook Accessibility: find and populate the actual compose subject/body controls.
p = root / 'app' / 'OutlookAccessibility.swift'
s = p.read_text()
insert_at = s.index('    func focusedWindowFrameInAppKitCoordinates()')
compose_methods = r'''    func setComposeSubjectValue(_ subject: String) -> Bool {
        guard let window = focusedOutlookWindow(), let element = composeSubjectElement(in: window) else { return false }
        return setValue(subject, on: element)
    }

    func setComposeBodyValue(_ body: String) -> Bool {
        guard let window = focusedOutlookWindow(), let element = composeBodyElement(in: window) else { return false }
        return setValue(body, on: element)
    }

    func focusComposeSubjectField() -> Bool {
        guard let window = focusedOutlookWindow(), let element = composeSubjectElement(in: window) else { return false }
        return focus(element)
    }

    func focusComposeBodyField() -> Bool {
        guard let window = focusedOutlookWindow(), let element = composeBodyElement(in: window) else { return false }
        return focus(element)
    }

    private func focusedOutlookWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.microsoft.Outlook" }) else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return axElementAttribute(kAXFocusedWindowAttribute as CFString, from: appElement)
    }

    private func composeSubjectElement(in window: AXUIElement) -> AXUIElement? {
        var stack: [AXUIElement] = [window]
        var visited = 0
        var fallback: [(AXUIElement, CGFloat)] = []
        let windowY = pointAttribute(kAXPositionAttribute as CFString, from: window)?.y ?? 0
        let windowHeight = sizeAttribute(kAXSizeAttribute as CFString, from: window)?.height ?? 900

        while let element = stack.popLast(), visited < 14_000 {
            visited += 1
            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" {
                let meta = composeMetadata(for: element)
                if meta.contains("subject") || meta.contains("betreff") {
                    return element
                }

                if isValueSettable(element),
                   let size = sizeAttribute(kAXSizeAttribute as CFString, from: element),
                   let pos = pointAttribute(kAXPositionAttribute as CFString, from: element),
                   size.width > 260, size.height < 90,
                   pos.y < windowY + windowHeight * 0.55 {
                    fallback.append((element, pos.y))
                }
            }
            for child in children(of: element).reversed() { stack.append(child) }
        }

        // In compose windows the subject field is normally the lowest wide editable single-line field
        // below To/Cc/Bcc, so use it as a language-independent fallback.
        return fallback.max(by: { $0.1 < $1.1 })?.0
    }

    private func composeBodyElement(in window: AXUIElement) -> AXUIElement? {
        var stack: [AXUIElement] = [window]
        var visited = 0
        var best: (AXUIElement, CGFloat)?

        while let element = stack.popLast(), visited < 14_000 {
            visited += 1
            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            if role == "AXTextArea" || role == "AXWebArea" {
                let meta = composeMetadata(for: element)
                if meta.contains("message body") || meta.contains("mail body") || meta.contains("nachrichtentext") || meta.contains("compose body") {
                    return element
                }

                if let size = sizeAttribute(kAXSizeAttribute as CFString, from: element),
                   size.width > 300, size.height > 120 {
                    let area = size.width * size.height
                    if best == nil || area > best!.1 { best = (element, area) }
                }
            }
            for child in children(of: element).reversed() { stack.append(child) }
        }
        return best?.0
    }

    private func composeMetadata(for element: AXUIElement) -> String {
        let attrs: [CFString] = [
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString,
            "AXPlaceholderValue" as CFString,
            "AXIdentifier" as CFString,
            "AXDOMIdentifier" as CFString,
            "AXRoleDescription" as CFString
        ]
        return attrs.compactMap { stringAttribute($0, from: element) }
            .joined(separator: " ")
            .lowercased()
    }

    private func isValueSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    private func setValue(_ value: String, on element: AXUIElement) -> Bool {
        guard isValueSettable(element) else { return false }
        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef) == .success
    }

    private func focus(_ element: AXUIElement) -> Bool {
        if AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            return true
        }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

'''
s = s[:insert_at] + compose_methods + s[insert_at:]
p.write_text(s)

# 5) Preview UI: show editable Subject and Body for New Mail.
p = root / 'app' / 'OverlayView.swift'
s = p.read_text()
old_preview = '''            TextEditor(text: $state.reply)\n                .font(.body)\n                .frame(height: 190)\n                .padding(8)\n                .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))\n'''
new_preview = '''            if state.outputMode == .newMail {\n                VStack(alignment: .leading, spacing: 6) {\n                    Text("Betreff").font(.caption).foregroundStyle(.secondary)\n                    TextField("Betreff", text: $state.newMailSubject)\n                        .textFieldStyle(.roundedBorder)\n                }\n\n                VStack(alignment: .leading, spacing: 6) {\n                    Text("Mailtext").font(.caption).foregroundStyle(.secondary)\n                    TextEditor(text: $state.reply)\n                        .font(.body)\n                        .frame(height: 190)\n                        .padding(8)\n                        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))\n                }\n            } else {\n                TextEditor(text: $state.reply)\n                    .font(.body)\n                    .frame(height: 190)\n                    .padding(8)\n                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))\n            }\n'''
if old_preview not in s:
    raise SystemExit('preview TextEditor block not found')
s = s.replace(old_preview, new_preview, 1)

mode_anchor = '''        case .newMail:\n            state.instruction = ""\n            state.selectedCommandName = "Custom"\n            state.replyTone = .professional\n'''
if mode_anchor not in s:
    raise SystemExit('newMail mode anchor not found')
s = s.replace(mode_anchor, mode_anchor + '            state.newMailSubject = ""\n', 1)
p.write_text(s)

# 6) Version and update package.
p = root / 'app' / 'Info.plist'
s = p.read_text()
s = s.replace('<string>1.16.0</string>', '<string>1.17.0</string>', 1)
s = s.replace('<string>17</string>', '<string>18</string>', 1)
p.write_text(s)

p = root / 'Build-CI.sh'
s = p.read_text()
s = s.replace('Replyzen-update-1.16.zip', 'Replyzen-update-1.17.zip')
s = s.replace('Replyzen 1.16: Der Outlook-Button zeigt jetzt den Namen Replyzen und das echte Replyzen-Logo statt ✨ AI.',
              'Replyzen 1.17: New Mail erzeugt immer einen eigenen Betreff und Mailtext und befüllt beide Outlook-Felder automatisch; Preview zeigt beide Felder separat.')
p.write_text(s)
