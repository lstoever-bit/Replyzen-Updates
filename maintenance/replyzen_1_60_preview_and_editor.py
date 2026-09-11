#!/usr/bin/env python3
"""ReplyZen 1.60: native editor shortcuts/wrapping and exact ChatGPT transfer preview."""
from pathlib import Path
import json
import plistlib
import sys

root = Path(sys.argv[1])
repo = root.parent
app = root / "app"
info_path = app / "Info.plist"
info = plistlib.loads(info_path.read_bytes())


def replace_once(text, before, after, label):
    count = text.count(before)
    if count != 1:
        raise RuntimeError(f"{label}: expected one marker, found {count}")
    return text.replace(before, after, 1)


def replace_between(text, start, end, replacement, label):
    a = text.find(start)
    if a < 0:
        raise RuntimeError(f"{label}: start marker missing")
    b = text.find(end, a)
    if b < 0:
        raise RuntimeError(f"{label}: end marker missing")
    return text[:a] + replacement + text[b:]


if info.get("CFBundleShortVersionString") == "1.60.0":
    editor = (app / "RichTextMailEditor.swift").read_text(encoding="utf-8")
    delegate = (app / "AppDelegate.swift").read_text(encoding="utf-8")
    workspace = (app / "MailWorkspaceView.swift").read_text(encoding="utf-8")
    assert "installShortcutMonitor" in editor
    assert "hasHorizontalScroller = false" in editor
    assert "TransferPreviewWindowController" in delegate
    assert "previewBeforeChatGPT" in workspace
    assert "payload.apiJSON" in (app / "OpenAIClient.swift").read_text(encoding="utf-8")
    print("ReplyZen 1.60 migration already applied")
    raise SystemExit(0)

if info.get("CFBundleShortVersionString") != "1.59.0" or str(info.get("CFBundleVersion")) != "60":
    raise SystemExit("Unexpected ReplyZen source version; refusing to modify")

# App state: persistent opt-in preview checkbox.
state_path = app / "AppState.swift"
state = state_path.read_text(encoding="utf-8")
state = replace_once(
    state,
    '    @Published var newMailCompact: Bool = false\n',
    '    @Published var newMailCompact: Bool = false\n'
    '    @Published var previewBeforeChatGPT: Bool = UserDefaults.standard.bool(forKey: "ReplyZen.PreviewBeforeChatGPT") {\n'
    '        didSet { UserDefaults.standard.set(previewBeforeChatGPT, forKey: "ReplyZen.PreviewBeforeChatGPT") }\n'
    '    }\n',
    "preview preference",
)
state_path.write_text(state, encoding="utf-8")

# Editor: support both macOS Command shortcuts and the explicitly requested Ctrl shortcuts.
# Also make wrapping zoom-aware so there is never horizontal scrolling.
editor_path = app / "RichTextMailEditor.swift"
editor = editor_path.read_text(encoding="utf-8")
editor = replace_once(
    editor,
    '    private var zoomObservation: NSKeyValueObservation?\n',
    '    private var zoomObservation: NSKeyValueObservation?\n    private var keyMonitor: Any?\n',
    "editor key monitor property",
)
editor = replace_once(
    editor,
    '''    deinit {
        if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
    }
''',
    '''    deinit {
        if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
''',
    "editor deinit",
)
editor = replace_once(
    editor,
    '''                let percent = Int((scrollView.magnification * 100).rounded())
                if percent != self.zoomPercent { self.zoomPercent = percent }
''',
    '''                let percent = Int((scrollView.magnification * 100).rounded())
                if percent != self.zoomPercent { self.zoomPercent = percent }
                self.updateWrapWidth()
''',
    "zoom observer wrapping",
)
editor = replace_once(
    editor,
    '''        zoomPercent = clamped
        UserDefaults.standard.set(clamped, forKey: "ReplyZen.EditorZoomPercent")
''',
    '''        zoomPercent = clamped
        UserDefaults.standard.set(clamped, forKey: "ReplyZen.EditorZoomPercent")
        updateWrapWidth()
''',
    "zoom setter wrapping",
)
editor = replace_once(
    editor,
    '''        textView = view
        configure(view)
        if let storage = view.textStorage {
''',
    '''        textView = view
        configure(view)
        installShortcutMonitor(for: view)
        updateWrapWidth()
        if let storage = view.textStorage {
''',
    "attach editor shortcuts",
)
insert_marker = '    func toggleBold() { toggleFontTrait(.boldFontMask) }\n'
editor_helpers = r'''    func refreshWrapping() {
        updateWrapWidth()
    }

    private func updateWrapWidth() {
        guard let scrollView, let textView else { return }
        let scale = max(CGFloat(1.0), scrollView.magnification)
        let width = max(CGFloat(120), scrollView.contentSize.width / scale)
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        var frame = textView.frame
        frame.size.width = width
        frame.size.height = max(frame.size.height, scrollView.contentSize.height / scale)
        textView.frame = frame
        var origin = scrollView.contentView.bounds.origin
        origin.x = 0
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func installShortcutMonitor(for view: RichTextView) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
            guard let self, let view, self.textView === view,
                  view.window?.firstResponder === view else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) || flags.contains(.control),
                  let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
            switch key {
            case "a":
                view.selectAll(nil)
                return nil
            case "c":
                view.copy(nil)
                return nil
            case "v":
                view.paste(nil)
                return nil
            case "x":
                view.cut(nil)
                return nil
            case "z":
                if flags.contains(.shift) { view.undoManager?.redo() } else { view.undoManager?.undo() }
                return nil
            default:
                return event
            }
        }
    }

'''
editor = replace_once(editor, insert_marker, editor_helpers + insert_marker, "editor shortcut helpers")
editor = replace_once(
    editor,
    '''        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
''',
    '''        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
''',
    "disable horizontal editor scrolling",
)
editor = replace_once(
    editor,
    '''    func updateNSView(_ scroll: NSScrollView, context: Context) {
        adapter.attachZoom(to: scroll)
        if let view = scroll.documentView as? RichTextView { adapter.attach(view) }
    }
''',
    '''    func updateNSView(_ scroll: NSScrollView, context: Context) {
        adapter.attachZoom(to: scroll)
        if let view = scroll.documentView as? RichTextView { adapter.attach(view) }
        adapter.refreshWrapping()
    }
''',
    "refresh wrapping on layout",
)
editor_path.write_text(editor, encoding="utf-8")

# Workspace: no app-generated default reply text. Add one clear preview checkbox.
workspace_path = app / "MailWorkspaceView.swift"
workspace = workspace_path.read_text(encoding="utf-8")
workspace = replace_once(
    workspace,
    '''        case .reply:
            if trimmed.isEmpty {
                state.instruction = state.replyLanguage.defaultReplyInstruction
                state.instructionHTML = ""
            }
''',
    '''        case .reply:
            break
''',
    "remove default reply text on mode change",
)
workspace = replace_once(
    workspace,
    '''        } else if state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.instruction = state.replyLanguage.defaultReplyInstruction
            state.instructionHTML = ""
        }
''',
    '''        }
''',
    "remove default reply text on scope change",
)
workspace = replace_once(
    workspace,
    '''                    optionsRow
                        .fixedSize(horizontal: false, vertical: true)
                    reminderControl
''',
    '''                    optionsRow
                        .fixedSize(horizontal: false, vertical: true)
                    transferPreviewControl
                        .fixedSize(horizontal: false, vertical: true)
                    reminderControl
''',
    "preview checkbox placement",
)
preview_view = '''    private var transferPreviewControl: some View {
        HStack {
            Toggle(isOn: $state.previewBeforeChatGPT) {
                Label(L10n.tr("Übergabe vor ChatGPT anzeigen"), systemImage: "eye")
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help(L10n.tr("Zeigt vor dem Senden genau die Daten, die an ChatGPT übergeben werden."))
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
    }

'''
workspace = replace_once(workspace, '    private var reminderControl: some View {\n', preview_view + '    private var reminderControl: some View {\n', "preview control")
workspace_path.write_text(workspace, encoding="utf-8")

# Delegate: wire the separate preview window, freeze the exact payload shown, then send that same payload.
delegate_path = app / "AppDelegate.swift"
delegate = delegate_path.read_text(encoding="utf-8")
delegate = replace_once(
    delegate,
    '    private let calendarManager = CalendarManager()\n',
    '    private let calendarManager = CalendarManager()\n    private let transferPreviewWindow = TransferPreviewWindowController()\n',
    "preview controller property",
)
delegate = replace_once(
    delegate,
    '''        if requestedMailMode == .reply {
            state.outputMode = .reply
            state.instruction = defaultReplyInstruction(for: state.replyLanguage)
''',
    '''        if requestedMailMode == .reply {
            state.outputMode = .reply
            state.instruction = ""
''',
    "blank reply editor",
)
delegate = replace_once(
    delegate,
    '''        if state.outputMode == .reply {
            panel.selectInstructionTextSoon(expectedText: state.instruction)
        }
        refreshMailContext()
''',
    '''        refreshMailContext()
''',
    "no initial auto selection",
)
old_completion = '''                    if self.state.outputMode == .reply {
                        let initialWasDefault = instructionAtLoadStart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            self.isDefaultReplyInstruction(instructionAtLoadStart)
                        let userHasNotEdited = self.state.instruction == instructionAtLoadStart
                        if initialWasDefault && userHasNotEdited {
                            self.state.instruction = self.defaultReplyInstruction(for: self.state.replyLanguage)
                            self.state.instructionHTML = ""
                        }
                        // Never select text when asynchronous mail loading finishes.
                        // The user may already be typing in the instruction editor.
                    }
'''
delegate = replace_once(delegate, old_completion, '', "never alter typed reply after mail load")
# The load-start snapshot is no longer needed once ReplyZen never injects default text.
delegate = replace_once(delegate, '        let instructionAtLoadStart = state.instruction\n\n', '', "remove load instruction snapshot")

start = '    private func generateReply() {'
end = '    private func generateCalendarSuggestion() {'
mail_generation = r'''    private func chatGPTLanguageCode() -> String {
        switch state.replyLanguage {
        case .german: return "de"
        case .usEnglish: return "en-US"
        case .spanish: return "es"
        }
    }

    private func makeTransferPayload(action: String, mailThread: String?) -> ChatGPTTransferPayload? {
        let userText = state.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty else { return nil }
        let html = state.instructionHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatGPTTransferPayload(
            action: action,
            mailThread: mailThread.map { String($0.prefix(30_000)) },
            userText: userText,
            userHTML: html.isEmpty ? nil : html,
            tone: state.replyTone.rawValue,
            language: chatGPTLanguageCode(),
            compact: state.newMailCompact
        )
    }

    private func sendWithOptionalPreview(_ payload: ChatGPTTransferPayload, send: @escaping () -> Void) {
        guard state.previewBeforeChatGPT else {
            send()
            return
        }
        transferPreviewWindow.show(payload: payload) { accepted in
            if accepted { send() }
        }
    }

    private func generateReply() {
        guard let apiKey = keychain.loadAPIKey() else {
            state.stage = .apiKey
            return
        }
        guard !state.mailText.isEmpty else {
            state.mailStatus = .unavailable(L10n.source("Keine lesbare Outlook-Mail erkannt. Nutze New Mail oder versuche es erneut."))
            return
        }
        let action = state.replyScope == .all ? "reply_all" : "reply"
        guard let payload = makeTransferPayload(action: action, mailThread: state.mailText) else { return }
        sendWithOptionalPreview(payload) { [weak self] in
            self?.performReply(payload, apiKey: apiKey)
        }
    }

    private func performReply(_ payload: ChatGPTTransferPayload, apiKey: String) {
        isRunningFlow = true
        toolbarButton.setSuppressed(true)
        state.stage = .generating
        state.statusText = L10n.source("OpenAI verarbeitet die Mail")
        openAI.generateReply(apiKey: apiKey, payload: payload) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunningFlow = false
                switch result {
                case .success(let draft):
                    self.state.reply = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.state.replyHTML = draft.html?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self.insertReply()
                case .failure(let error):
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func generateNewMail() {
        guard let apiKey = keychain.loadAPIKey() else {
            state.stage = .apiKey
            return
        }
        guard let payload = makeTransferPayload(action: "new_mail", mailThread: nil) else { return }
        sendWithOptionalPreview(payload) { [weak self] in
            self?.performNewMail(payload, apiKey: apiKey)
        }
    }

    private func performNewMail(_ payload: ChatGPTTransferPayload, apiKey: String) {
        isRunningFlow = true
        toolbarButton.setSuppressed(true)
        state.stage = .generating
        state.statusText = L10n.source("OpenAI formuliert eine neue Mail")
        openAI.generateNewMail(apiKey: apiKey, payload: payload) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunningFlow = false
                switch result {
                case .success(let draft):
                    self.state.newMailSubject = draft.subject.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.state.reply = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.state.replyHTML = draft.html?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self.insertNewMail()
                case .failure(let error):
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func forwardWithNote() {
        guard let apiKey = keychain.loadAPIKey() else {
            state.stage = .apiKey
            return
        }
        guard !state.mailText.isEmpty, activeSnapshot != nil else {
            state.mailStatus = .unavailable(L10n.source("Keine lesbare Outlook-Mail erkannt. Für Forward bitte eine Mail öffnen und erneut versuchen."))
            return
        }
        guard let payload = makeTransferPayload(action: "forward", mailThread: state.mailText) else { return }
        sendWithOptionalPreview(payload) { [weak self] in
            self?.performForward(payload, apiKey: apiKey)
        }
    }

    private func performForward(_ payload: ChatGPTTransferPayload, apiKey: String) {
        isRunningFlow = true
        toolbarButton.setSuppressed(true)
        state.stage = .generating
        state.statusText = L10n.source("OpenAI formuliert den Forward Text")
        openAI.generateForwardNote(apiKey: apiKey, payload: payload) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunningFlow = false
                switch result {
                case .success(let draft):
                    self.state.reply = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.state.replyHTML = draft.html?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self.insertForwardDraft()
                case .failure(let error):
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

'''
delegate = replace_between(delegate, start, end, mail_generation, "mail generation pipeline")
delegate_path.write_text(delegate, encoding="utf-8")

# OpenAI: the exact JSON shown in preview is the exact input passed to the Responses API.
client_path = app / "OpenAIClient.swift"
client = client_path.read_text(encoding="utf-8")
reply_start = '    func generateReply('
forward_start = '    func generateForwardNote('
quick_start = '    func generateQuickDecline('
new_start = '    func generateNewMail('
dash_start = '    private var restrainedDashInstruction: String {'
reply_func = r'''    func generateReply(
        apiKey: String,
        payload: ChatGPTTransferPayload,
        completion: @escaping (Result<ReplyDraft, Error>) -> Void
    ) {
        var rules = commonMailRules(payload: payload, purpose: "reply")
        rules.append("Return ONLY valid JSON with exactly these keys: body, html.")
        rules.append("body is the plain text final reply. html is the same reply as clean email-safe HTML using only p, br, strong, em, ul, ol and li.")
        rules.append("Do not add a subject line or signature.")
        performRequest(apiKey: apiKey, instructions: rules.joined(separator: "\n"), input: payload.apiJSON,
                       maxOutputTokens: payload.compact ? 340 : 700, lowVerbosity: true) { result in
            switch result {
            case .success(let text):
                do { completion(.success(try Self.decodeReplyDraft(text))) }
                catch { completion(.failure(error)) }
            case .failure(let error): completion(.failure(error))
            }
        }
    }

'''
client = replace_between(client, reply_start, forward_start, reply_func, "reply payload API")
forward_func = r'''    func generateForwardNote(
        apiKey: String,
        payload: ChatGPTTransferPayload,
        completion: @escaping (Result<ReplyDraft, Error>) -> Void
    ) {
        var rules = commonMailRules(payload: payload, purpose: "forwarding note")
        rules.append("Return ONLY valid JSON with exactly these keys: body, html.")
        rules.append("body is only the note placed above the forwarded thread. html is the same note as clean email-safe HTML using only p, br, strong, em, ul, ol and li.")
        rules.append("Do not reproduce the forwarded thread, add recipients, a subject line or a signature.")
        performRequest(apiKey: apiKey, instructions: rules.joined(separator: "\n"), input: payload.apiJSON,
                       maxOutputTokens: payload.compact ? 340 : 700, lowVerbosity: true) { result in
            switch result {
            case .success(let text):
                do { completion(.success(try Self.decodeReplyDraft(text))) }
                catch { completion(.failure(error)) }
            case .failure(let error): completion(.failure(error))
            }
        }
    }

'''
client = replace_between(client, forward_start, quick_start, forward_func, "forward payload API")
new_func = r'''    func generateNewMail(
        apiKey: String,
        payload: ChatGPTTransferPayload,
        completion: @escaping (Result<NewMailDraft, Error>) -> Void
    ) {
        var rules = commonMailRules(payload: payload, purpose: "new email")
        rules.append("Return ONLY valid JSON with exactly these keys: subject, body, html.")
        rules.append("Create a short useful subject using only the user's provided content. Do not invent a topic.")
        rules.append("body is the plain text email body. html is the same body as clean email-safe HTML using only p, br, strong, em, ul, ol and li.")
        rules.append("Do not add a signature unless the user text explicitly asks for one.")
        performRequest(apiKey: apiKey, instructions: rules.joined(separator: "\n"), input: payload.apiJSON,
                       maxOutputTokens: payload.compact ? 380 : 760, lowVerbosity: true) { result in
            switch result {
            case .success(let text):
                do { completion(.success(try Self.decodeNewMailDraft(text))) }
                catch { completion(.failure(error)) }
            case .failure(let error): completion(.failure(error))
            }
        }
    }

    private func commonMailRules(payload: ChatGPTTransferPayload, purpose: String) -> [String] {
        var rules = [
            "Formulate the \(purpose) using only the information contained in the JSON input.",
            "user_text is authoritative. Preserve every explicit point from user_text.",
            "mail_thread is context only. Use it to understand references in user_text, but do not introduce a new substantive point merely because it appears in the thread.",
            "Do not invent or infer facts, reasons, promises, commitments, dates, names, numbers, attachments, recipients, opinions, decisions or next steps that the user did not provide.",
            "Do not silently omit a requested point. You may improve grammar, structure and natural phrasing without changing meaning.",
            "If user_html is present, preserve its intentional bold, italic, bullet and numbered-list cues where appropriate.",
            "Tone setting is \(payload.tone).",
            "Output language setting is \(payload.language): de means German, en-US means natural US English, es means natural Spanish.",
            restrainedDashInstruction
        ]
        if payload.compact {
            rules.append("Compact is true: make the result as short as possible while preserving every requested point.")
        } else {
            rules.append("Compact is false: use only the length needed to express the user's requested points clearly; do not add filler.")
        }
        return rules
    }

'''
client = replace_between(client, new_start, dash_start, new_func, "new mail payload API")
client_path.write_text(client, encoding="utf-8")

# Localization for the new checkbox and separate preview window.
loc_path = app / "Resources" / "Localization.json"
loc = json.loads(loc_path.read_text(encoding="utf-8"))
new_strings = {
    "Übergabe vor ChatGPT anzeigen": {"de": "Übergabe vor ChatGPT anzeigen", "en-US": "Preview before ChatGPT", "es": "Vista previa antes de ChatGPT"},
    "Zeigt vor dem Senden genau die Daten, die an ChatGPT übergeben werden.": {"de": "Zeigt vor dem Senden genau die Daten, die an ChatGPT übergeben werden.", "en-US": "Shows the exact data that will be sent to ChatGPT before sending.", "es": "Muestra los datos exactos que se enviarán a ChatGPT antes de enviarlos."},
    "Übergabe an ChatGPT prüfen": {"de": "Übergabe an ChatGPT prüfen", "en-US": "Review data sent to ChatGPT", "es": "Revisar datos enviados a ChatGPT"},
    "Diese Daten werden an ChatGPT übergeben": {"de": "Diese Daten werden an ChatGPT übergeben", "en-US": "This data will be sent to ChatGPT", "es": "Estos datos se enviarán a ChatGPT"},
    "Prüfe den Inhalt. Erst nach deiner Bestätigung wird genau dieser Datenblock gesendet.": {"de": "Prüfe den Inhalt. Erst nach deiner Bestätigung wird genau dieser Datenblock gesendet.", "en-US": "Review the content. This exact data block is sent only after you confirm.", "es": "Revisa el contenido. Este bloque de datos exacto solo se enviará después de tu confirmación."},
    "An ChatGPT senden": {"de": "An ChatGPT senden", "en-US": "Send to ChatGPT", "es": "Enviar a ChatGPT"}
}
loc.update(new_strings)
loc_path.write_text(json.dumps(loc, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")

# Release metadata.
info["CFBundleShortVersionString"] = "1.60.0"
info["CFBundleVersion"] = "61"
info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
notes = {
    "de": "ReplyZen 1.60: Der WYSIWYG-Editor unterstützt jetzt Command/Strg+A, C, V und X zuverlässig und bricht Text immer innerhalb der Editorbreite um, ohne horizontales Scrollen. Reply, Reply All, New Mail und Forward senden an ChatGPT nur den relevanten Mailverlauf (außer New Mail), deinen geschriebenen Text einschließlich Formatierung sowie Ton, Sprache und Compact. Optional zeigt ein Hakenfeld vorab in einem separaten Fenster exakt den JSON-Datenblock; erst nach Bestätigung wird genau dieser Block gesendet. ReplyZen ergänzt keine eigenen inhaltlichen Annahmen.",
    "en-US": "ReplyZen 1.60: The WYSIWYG editor now reliably supports Command/Ctrl+A, C, V and X and always wraps text within the editor width with no horizontal scrolling. Reply, Reply All, New Mail and Forward send ChatGPT only the relevant mail thread (except New Mail), your written text including formatting, plus tone, language and Compact. An optional checkbox shows the exact JSON data block in a separate preview window; that exact block is sent only after confirmation. ReplyZen does not add its own substantive assumptions.",
    "es": "ReplyZen 1.60: El editor WYSIWYG admite ahora de forma fiable Command/Ctrl+A, C, V y X y ajusta siempre el texto al ancho del editor sin desplazamiento horizontal. Reply, Reply All, New Mail y Forward envían a ChatGPT solo el hilo relevante (excepto New Mail), tu texto escrito con su formato, además del tono, idioma y Compact. Una casilla opcional muestra antes el bloque JSON exacto en una ventana separada; solo después de confirmarlo se envía exactamente ese bloque. ReplyZen no añade supuestos de contenido propios."
}
(root / "Release-notes.txt").write_text(notes["de"] + "\n", encoding="utf-8")
(root / "Release-notes.localized.json").write_text(json.dumps(notes, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

# Update source contracts and updater verification.
test_path = repo / "tests" / "test_source_contracts.py"
test = test_path.read_text(encoding="utf-8")
test = test.replace('self.assertEqual(info["CFBundleShortVersionString"], "1.59.0")', 'self.assertEqual(info["CFBundleShortVersionString"], "1.60.0")')
test = test.replace('self.assertEqual(info["CFBundleVersion"], "60")', 'self.assertEqual(info["CFBundleVersion"], "61")')
extra = r'''
    def test_editor_shortcuts_wrapping_and_exact_transfer_preview(self):
        editor = self.read("RichTextMailEditor.swift")
        state = self.read("AppState.swift")
        workspace = self.read("MailWorkspaceView.swift")
        delegate = self.read("AppDelegate.swift")
        client = self.read("OpenAIClient.swift")
        payload = self.read("ChatGPTTransferPayload.swift")
        preview = self.read("TransferPreviewWindowController.swift")
        self.assertIn("NSEvent.addLocalMonitorForEvents", editor)
        self.assertIn("flags.contains(.command) || flags.contains(.control)", editor)
        for call in ["view.selectAll(nil)", "view.copy(nil)", "view.paste(nil)", "view.cut(nil)"]:
            self.assertIn(call, editor)
        self.assertIn("scroll.hasHorizontalScroller = false", editor)
        self.assertIn("scroll.horizontalScrollElasticity = .none", editor)
        self.assertIn("widthTracksTextView = true", editor)
        self.assertIn("previewBeforeChatGPT", state)
        self.assertIn("Übergabe vor ChatGPT anzeigen", workspace)
        self.assertIn("TransferPreviewWindowController", delegate)
        self.assertIn('action = state.replyScope == .all ? "reply_all" : "reply"', delegate)
        self.assertIn('action: "new_mail", mailThread: nil', delegate)
        self.assertIn('action: "forward", mailThread: state.mailText', delegate)
        self.assertGreaterEqual(client.count("input: payload.apiJSON"), 3)
        self.assertIn("mail_thread is context only", client)
        self.assertIn("Do not invent or infer facts", client)
        self.assertIn("sortedKeys", payload)
        self.assertIn("textView.string = payload.apiJSON", preview)
        self.assertIn("An ChatGPT senden", preview)
'''
insert = '\n    def test_overlay_restores_after_workspace_close(self):\n'
if extra.strip() not in test:
    test = test.replace(insert, extra + insert, 1)
test_path.write_text(test, encoding="utf-8")

verify_path = repo / "tests" / "verify_update.py"
verify = verify_path.read_text(encoding="utf-8")
verify = verify.replace("manifest['version'] == '1.59.0' and manifest['build'] == 60", "manifest['version'] == '1.60.0' and manifest['build'] == 61")
verify = verify.replace("Replyzen-update-1.59.zip", "Replyzen-update-1.60.zip")
verify = verify.replace("PASS: 1.59", "PASS: 1.60")
verify_path.write_text(verify, encoding="utf-8")

print("Migrated ReplyZen to 1.60.0 / build 61")
