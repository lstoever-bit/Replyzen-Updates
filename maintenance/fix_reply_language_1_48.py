#!/usr/bin/env python3
"""Checked one-time migration from ReplyZen 1.47 to 1.48.

Fixes newest-message language detection, adds Spanish as an email output language,
and makes Reply vs Reply All explicit and resilient to Outlook focus/compose timing.
"""
from pathlib import Path
import json
import plistlib
import sys

root = Path(sys.argv[1])
app = root / "app"
info_path = app / "Info.plist"
info = plistlib.loads(info_path.read_bytes())
version = info.get("CFBundleShortVersionString")
if version == "1.48.0":
    print("ReplyZen 1.48 migration already applied")
    raise SystemExit(0)
if version != "1.47.0" or info.get("CFBundleVersion") != "48":
    raise SystemExit(f"Refusing unexpected source version/build: {version}/{info.get('CFBundleVersion')}")


def read(name: str) -> str:
    return (app / name).read_text(encoding="utf-8")


def write(name: str, text: str) -> None:
    (app / name).write_text(text, encoding="utf-8")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if text.count(old) != 1:
        raise RuntimeError(f"Expected exactly one {label}; found {text.count(old)}")
    return text.replace(old, new, 1)


def replace_between(text: str, start: str, end: str, replacement: str, label: str) -> str:
    try:
        a = text.index(start)
        b = text.index(end, a)
    except ValueError as exc:
        raise RuntimeError(f"Could not locate {label}") from exc
    return text[:a] + replacement + text[b:]


# App state: three email languages and explicit reply scope.
s = read("AppState.swift")
s = replace_between(
    s,
    "    enum ReplyLanguage:",
    "    enum MailStatus:",
    '''    enum ReplyLanguage: Equatable, CaseIterable {
        case german
        case usEnglish
        case spanish

        var displayName: String {
            switch self {
            case .german: return L10n.tr("Deutsch")
            case .usEnglish: return L10n.tr("US English")
            case .spanish: return L10n.tr("Español")
            }
        }

        var defaultReplyInstruction: String {
            switch self {
            case .german: return "Kurz, freundlich und direkt antworten."
            case .usEnglish: return "Reply briefly, friendly and directly."
            case .spanish: return "Responder de forma breve, amable y directa."
            }
        }
    }

    enum ReplyScope: Equatable {
        case sender
        case all
    }

''',
    "ReplyLanguage block",
)
s = replace_once(
    s,
    "    @Published var replyLanguage: ReplyLanguage = .german\n",
    "    @Published var replyLanguage: ReplyLanguage = .german\n    @Published var replyScope: ReplyScope = .all\n",
    "reply language property",
)
write("AppState.swift", s)

# Mail workspace: show Reply and Reply All as separate selected actions and expose ES.
s = read("MailWorkspaceView.swift")
logic = '''enum MailWorkspaceLogic {
    static func canGenerate(_ state: AppState) -> Bool {
        let hasInstruction = !state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch state.outputMode {
        case .newMail: return hasInstruction
        case .reply, .forward: return state.mailStatus == .available && hasInstruction
        case .calendar, .payment: return state.mailStatus == .available
        }
    }

    static func select(_ mode: AppState.OutputMode, in state: AppState) {
        guard state.outputMode != mode else { return }
        state.outputMode = mode
        let trimmed = state.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDefault = AppState.ReplyLanguage.allCases.map(\\.defaultReplyInstruction).contains(trimmed)
        switch mode {
        case .newMail, .forward:
            if isDefault {
                state.instruction = ""
                state.instructionHTML = ""
            }
            if mode == .newMail { state.newMailSubject = "" }
        case .reply:
            if trimmed.isEmpty {
                state.instruction = state.replyLanguage.defaultReplyInstruction
                state.instructionHTML = ""
            }
        case .calendar, .payment: break
        }
    }

    static func selectReply(all: Bool, in state: AppState) {
        state.replyScope = all ? .all : .sender
        if state.outputMode != .reply {
            select(.reply, in: state)
        } else if state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.instruction = state.replyLanguage.defaultReplyInstruction
            state.instructionHTML = ""
        }
    }
}

'''
s = replace_between(s, "enum MailWorkspaceLogic {", "struct MailWorkspaceView: View {", logic, "MailWorkspaceLogic")
mode_section = '''    private var modeRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                if hasMail {
                    replyButton(all: false)
                    replyButton(all: true)
                }
                modeButton(.newMail, symbol: "square.and.pencil")
                if hasMail { modeButton(.forward, symbol: "arrowshape.turn.up.right") }
            }
            .padding(3)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            Spacer(minLength: 4)
            contextLabel
        }
    }

    private func replyButton(all: Bool) -> some View {
        let scope: AppState.ReplyScope = all ? .all : .sender
        let selected = state.outputMode == .reply && state.replyScope == scope
        return Button { MailWorkspaceLogic.selectReply(all: all, in: state) } label: {
            Label(L10n.tr(all ? "Reply All" : "Reply"),
                  systemImage: all ? "arrowshape.turn.up.left.2" : "arrowshape.turn.up.left")
                .lineLimit(1)
        }
        .buttonStyle(WorkspaceChoiceStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func modeButton(_ mode: AppState.OutputMode, symbol: String) -> some View {
        Button { MailWorkspaceLogic.select(mode, in: state) } label: {
            Label(mode.displayName, systemImage: symbol).lineLimit(1)
        }
        .buttonStyle(WorkspaceChoiceStyle(selected: state.outputMode == mode))
        .accessibilityAddTraits(state.outputMode == mode ? .isSelected : [])
    }

'''
s = replace_between(s, "    private var modeRow: some View {", "    private var contextLabel: some View {", mode_section, "mail mode controls")
language_section = '''    private var languageSelector: some View {
        HStack(spacing: 2) {
            languageButton("DE", language: .german, title: L10n.tr("Deutsch"))
            languageButton("EN", language: .usEnglish, title: L10n.tr("US English"))
            languageButton("ES", language: .spanish, title: L10n.tr("Español"))
        }
        .padding(3)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain).accessibilityLabel(L10n.tr("Ausgabesprache"))
    }

'''
s = replace_between(s, "    private var languageSelector: some View {", "    private func languageButton", language_section, "output language selector")
write("MailWorkspaceView.swift", s)

# App delegate: preserve the explicit scope and wait for a real Outlook compose body.
s = read("AppDelegate.swift")
s = s.replace("    private var replyAllForCurrentDraft = true\n", "")
reply_openers = '''    private func openNewMailWorkspace() {
        requestedMailMode = .newMail
        openWorkspace()
    }

    private func openReplyWorkspace(replyAll: Bool) {
        requestedMailMode = .reply
        state.replyScope = replyAll ? .all : .sender
        openWorkspace()
    }

    private func openForwardWorkspace() {
        requestedMailMode = .forward
        openWorkspace()
    }

'''
s = replace_between(s, "    private func openNewMailWorkspace() {", "    private func createCalendarFromOverlay() {", reply_openers, "Outlook overlay openers")
s = replace_once(
    s,
    '''        if requestedMailMode != .reply {
            replyAllForCurrentDraft = true
        }
''',
    '''        if requestedMailMode == nil {
            state.replyScope = .all
        }
''',
    "generic reply-scope default",
)
language_helpers = '''    private func detectReplyLanguage(in mailText: String) -> AppState.ReplyLanguage? {
        MailLanguageDetector.detect(in: mailText)
    }

    private func defaultReplyInstruction(for language: AppState.ReplyLanguage) -> String {
        language.defaultReplyInstruction
    }

    private func isDefaultReplyInstruction(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppState.ReplyLanguage.allCases.map(\\.defaultReplyInstruction).contains(cleaned)
    }

'''
s = replace_between(s, "    private func detectReplyLanguage(in mailText: String)", "    private func refreshMailContext() {", language_helpers, "language helper functions")
reply_insert = '''    private func insertReply() {
        guard let snapshot = activeSnapshot else {
            state.stage = .instruction
            state.mailStatus = .unavailable(L10n.source("Die ursprüngliche Outlook-Mail ist nicht mehr verfügbar. Bitte erneut laden."))
            return
        }

        let reply = state.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return }

        guard outlook.isTrusted() else {
            copyMailToPasteboard(plainText: reply, html: state.replyHTML)
            showError(L10n.source("Replyzen braucht Bedienungshilfen, um den Text automatisch in Outlook einzusetzen. Der Text wurde in die Zwischenablage kopiert."))
            return
        }

        state.stage = .inserting
        state.statusText = L10n.source("Outlook wird aktiviert")
        isRunningFlow = true
        toolbarButton.setSuppressed(true)

        let replyAll = state.replyScope == .all
        copyMailToPasteboard(plainText: reply, html: state.replyHTML)
        panel.hide()
        outlook.activateOutlook(pid: snapshot.pid)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self else { return }
            let openedThroughAccessibility = self.outlook.openReplyComposer(replyAll: replyAll, from: snapshot)
            if !openedThroughAccessibility {
                if replyAll { self.keyboard.sendCommandShiftR() }
                else { self.keyboard.sendCommandR() }
            }
            self.populateReplyDraft(reply: reply, html: self.state.replyHTML, attempt: 0)
        }
    }

    private func populateReplyDraft(reply: String, html: String, attempt: Int) {
        let delay = attempt == 0 ? 0.45 : 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }

            if self.outlook.focusComposeBodyField() {
                if let reminder = self.reminderBCCAddress() {
                    _ = self.outlook.setComposeBCCValue(reminder)
                    _ = self.outlook.focusComposeBodyField()
                }
                self.copyMailToPasteboard(plainText: reply, html: html)
                self.keyboard.sendCommandV()
                self.finishNewMailInsertion()
                return
            }

            if attempt < 10 {
                self.populateReplyDraft(reply: reply, html: html, attempt: attempt + 1)
                return
            }

            self.copyMailToPasteboard(plainText: reply, html: html)
            self.isRunningFlow = false
            self.toolbarButton.setSuppressed(false)
            self.showError(L10n.source("Outlook hat den Antworteditor nicht geöffnet. Der Text wurde in die Zwischenablage kopiert."))
        }
    }

'''
s = replace_between(s, "    private func insertReply() {", "    private func insertForwardDraft() {", reply_insert, "reply insertion flow")
write("AppDelegate.swift", s)

# Outlook accessibility: target the captured message, prefer the actual Reply button,
# and never treat a read-only message web area as the compose editor.
s = read("OutlookAccessibility.swift")
reply_ax = '''    func openReplyComposer(replyAll: Bool, from snapshot: Snapshot) -> Bool {
        guard let sourceWindow = snapshot.windows.first else { return false }
        activateOutlook(pid: snapshot.pid)

        let appElement = AXUIElementCreateApplication(snapshot.pid)
        _ = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, sourceWindow)
        _ = AXUIElementPerformAction(sourceWindow, kAXRaiseAction as CFString)
        if looksLikeMainOutlookWindow(sourceWindow) {
            focusSelectedMessageRow(in: sourceWindow)
        }

        var stack: [AXUIElement] = [sourceWindow]
        var visited = 0
        var best: (element: AXUIElement, score: Int)?
        while let element = stack.popLast(), visited < 16_000 {
            visited += 1
            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            if role == "AXButton" || role == "AXMenuButton" || role == "AXLink" || role == "AXMenuItem" {
                let score = OutlookReplyControlMatcher.score(metadata: composeMetadata(for: element), replyAll: replyAll)
                if score > 0 && (best == nil || score > best!.score) {
                    best = (element, score)
                }
            }
            for child in children(of: element).reversed() { stack.append(child) }
        }

        guard let best else { return false }
        return AXUIElementPerformAction(best.element, kAXPressAction as CFString) == .success
    }

'''
s = replace_once(s, "    func setComposeBCCValue(_ bcc: String) -> Bool {", reply_ax + "    func setComposeBCCValue(_ bcc: String) -> Bool {", "reply accessibility entry point")
s = replace_once(s, '["bcc", "blind carbon", "blind copy", "blindkopie"]', '["bcc", "blind carbon", "blind copy", "blindkopie", "cco", "copia oculta"]', "BCC reveal labels")
s = replace_once(s, 'meta.contains("bcc") || meta.contains("blind carbon") || meta.contains("blind copy") || meta.contains("blindkopie")', 'meta.contains("bcc") || meta.contains("blind carbon") || meta.contains("blind copy") || meta.contains("blindkopie") || meta.contains("cco") || meta.contains("copia oculta")', "BCC field labels")
s = replace_once(s, 'if meta.contains("subject") || meta.contains("betreff") {', 'if meta.contains("subject") || meta.contains("betreff") || meta.contains("asunto") {', "subject labels")
s = replace_once(s, 'if meta.contains("message body") || meta.contains("mail body") || meta.contains("nachrichtentext") || meta.contains("compose body") {', 'if meta.contains("message body") || meta.contains("mail body") || meta.contains("nachrichtentext") || meta.contains("compose body") || meta.contains("cuerpo del mensaje") || meta.contains("cuerpo del correo") {', "compose body labels")
compose_tail = '''        return looksLikeComposeWindow(window) ? best?.0 : nil
    }

    private func looksLikeComposeWindow(_ window: AXUIElement) -> Bool {
        var stack: [AXUIElement] = [window]
        var visited = 0
        while let element = stack.popLast(), visited < 12_000 {
            visited += 1
            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            if role == "AXButton" || role == "AXMenuButton" {
                let meta = composeMetadata(for: element)
                if meta.contains("send") || meta.contains("senden") || meta.contains("enviar") {
                    return true
                }
            }
            for child in children(of: element).reversed() { stack.append(child) }
        }
        return false
    }

'''
s = replace_between(s, "        return best?.0\n    }\n\n    private func composeMetadata", "    private func composeMetadata", compose_tail, "compose fallback guard")
write("OutlookAccessibility.swift", s)

# OpenAI output language: Spanish is a first-class manual/auto-selected output language.
s = read("OpenAIClient.swift")
calendar_language = '''        let titleLanguage: String
        let strictLanguageInstruction: String
        switch language {
        case .german:
            titleLanguage = "German"
            strictLanguageInstruction = "OUTPUT LANGUAGE IS GERMAN. The title and description MUST be written in German, regardless of the language used in the email thread."
        case .usEnglish:
            titleLanguage = "US English"
            strictLanguageInstruction = "OUTPUT LANGUAGE IS US ENGLISH. The title and description MUST be written in natural US English, regardless of the language used in the email thread. Translate ordinary descriptive words; preserve only true proper names such as people, companies, products, and projects."
        case .spanish:
            titleLanguage = "Spanish"
            strictLanguageInstruction = "OUTPUT LANGUAGE IS SPANISH. The title and description MUST be written in natural Spanish, regardless of the language used in the email thread. Translate ordinary descriptive words; preserve only true proper names such as people, companies, products, and projects."
        }

'''
s = replace_between(s, "        let titleLanguage =", "        let systemInstructions = [", calendar_language, "calendar output language")
language_instruction = '''    private func languageInstruction(for language: AppState.ReplyLanguage, purpose: String) -> String {
        switch language {
        case .german:
            return "FINAL OUTPUT LANGUAGE IS GERMAN. Write the entire \\(purpose) in natural German. The USER INSTRUCTION may be written in any language; treat its language only as input and translate its requested meaning into German. Never switch the final email to another language because the instruction itself is written in that language. Preserve exact names, brands, URLs, email addresses and explicitly requested verbatim quotations."
        case .usEnglish:
            return "FINAL OUTPUT LANGUAGE IS US ENGLISH. Write the entire \\(purpose) in natural US English using American spelling and phrasing. The USER INSTRUCTION may be written in any language; treat its language only as input and translate its requested meaning into US English. Never switch the final email to German or another language because the instruction itself is written in that language. Preserve exact names, brands, URLs, email addresses and explicitly requested verbatim quotations."
        case .spanish:
            return "FINAL OUTPUT LANGUAGE IS SPANISH. Write the entire \\(purpose) in natural Spanish. The USER INSTRUCTION may be written in any language; treat its language only as input and translate its requested meaning into Spanish. Never switch the final email to German, English or another language because the instruction itself is written in that language. Preserve exact names, brands, URLs, email addresses and explicitly requested verbatim quotations."
        }
    }

'''
s = replace_between(s, "    private func languageInstruction(for language: AppState.ReplyLanguage", "    private func performRequest(", language_instruction, "OpenAI language instruction")
write("OpenAIClient.swift", s)

# Local OCR can now recognize Spanish invoices/attachments as well.
s = read("AttachmentTextExtractor.swift")
s = replace_once(s, 'request.recognitionLanguages = ["de-DE", "en-US"]', 'request.recognitionLanguages = ["de-DE", "en-US", "es-ES"]', "OCR languages")
write("AttachmentTextExtractor.swift", s)

# Build/test stubs must mirror the production enum.
stub = root.parent / "tests" / "ClientStubs.swift"
stub_text = stub.read_text(encoding="utf-8")
stub_text = replace_once(stub_text, "enum AppState { enum ReplyLanguage { case german, usEnglish } }", "enum AppState { enum ReplyLanguage { case german, usEnglish, spanish } }", "client reply-language stub")
stub.write_text(stub_text, encoding="utf-8")

# Localization catalog entries introduced by 1.48.
catalog_path = app / "Resources" / "Localization.json"
catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
catalog.setdefault("Español", {"en-US": "Spanish", "de": "Spanisch", "es": "Español"})
catalog.setdefault("Reply All", {"en-US": "Reply All", "de": "Allen antworten", "es": "Responder a todos"})
catalog.setdefault(
    "Outlook hat den Antworteditor nicht geöffnet. Der Text wurde in die Zwischenablage kopiert.",
    {
        "en-US": "Outlook did not open the reply editor. The text was copied to the clipboard.",
        "de": "Outlook hat den Antworteditor nicht geöffnet. Der Text wurde in die Zwischenablage kopiert.",
        "es": "Outlook no ha abierto el editor de respuesta. El texto se ha copiado al portapapeles."
    },
)
catalog_path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

# Version/build and release notes.
info["CFBundleShortVersionString"] = "1.48.0"
info["CFBundleVersion"] = "49"
info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
notes = {
    "de": "ReplyZen 1.48: Die Spracherkennung betrachtet jetzt gezielt die neueste Nachricht statt des gesamten zitierten Mailverlaufs und erkennt Deutsch, US English und Español. Reply und Reply All sind im Arbeitsfenster getrennt auswählbar. Beim Einsetzen wird zuerst der passende Outlook-Befehl direkt angesprochen und erst danach auf den Tastatur-Shortcut zurückgegriffen. ReplyZen wartet auf einen echten Antworteditor, bevor Text eingefügt wird.",
    "en-US": "ReplyZen 1.48: Language detection now focuses on the newest message instead of the full quoted thread and recognizes German, US English, and Spanish. Reply and Reply All are separate choices in the workspace. ReplyZen first targets the correct Outlook action directly, falls back to the keyboard shortcut only when needed, and waits for a real reply editor before inserting text.",
    "es": "ReplyZen 1.48: La detección de idioma ahora se centra en el mensaje más reciente y no en todo el hilo citado, y reconoce alemán, inglés de EE. UU. y español. Responder y Responder a todos se pueden elegir por separado. ReplyZen intenta primero la acción correcta de Outlook, usa el atajo de teclado solo como alternativa y espera a que el editor de respuesta esté realmente abierto antes de insertar el texto."
}
(root / "Release-notes.localized.json").write_text(json.dumps(notes, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
(root / "Release-notes.txt").write_text(notes["de"] + "\n", encoding="utf-8")

# Existing release assertions.
contracts = root.parent / "tests" / "test_source_contracts.py"
t = contracts.read_text(encoding="utf-8")
t = t.replace("'1.47.0'", "'1.48.0'").replace("'48'", "'49'", 1)
needle = "        self.assertIn('openSelectedMessageWindowIfNeeded', self.read('OutlookAccessibility.swift'))\n"
if needle not in t:
    raise RuntimeError("Source-contract Outlook marker changed")
t = t.replace(needle, needle + "        self.assertIn('openReplyComposer(replyAll:', self.read('OutlookAccessibility.swift'))\n        self.assertIn('replyScope', self.read('AppState.swift'))\n        self.assertIn('case spanish', self.read('AppState.swift'))\n")
contracts.write_text(t, encoding="utf-8")

verify = root.parent / "tests" / "verify_update.py"
t = verify.read_text(encoding="utf-8")
t = t.replace("'1.47.0' and manifest['build'] == 48", "'1.48.0' and manifest['build'] == 49")
t = t.replace("'Replyzen-update-1.47.zip'", "'Replyzen-update-1.48.zip'")
t = t.replace("PASS: 1.47 version/build", "PASS: 1.48 version/build")
verify.write_text(t, encoding="utf-8")

run_localization = root.parent / "tests" / "run-localization-tests.sh"
t = run_localization.read_text(encoding="utf-8")
marker = '"$TMP/localization-tests"\n'
behavior = '''"$TMP/localization-tests"
swiftc -parse-as-library -framework NaturalLanguage \\
 "$SOURCE/app/MailLanguageDetector.swift" "$SOURCE/app/OutlookReplyControlMatcher.swift" \\
 "$ROOT/tests/ReplyBehaviorTests.swift" -o "$TMP/reply-behavior-tests"
"$TMP/reply-behavior-tests"
'''
t = replace_once(t, marker, behavior, "reply behavior test hook")
run_localization.write_text(t, encoding="utf-8")

print("Migrated ReplyZen to 1.48.0 / build 49")
