import AppKit
import ApplicationServices
import NaturalLanguage

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private lazy var panel = FloatingPanelController(state: state)
    private let outlook = OutlookAccessibility()
    private let openAI = OpenAIClient()
    private let keychain = KeychainStore()
    private let keyboard = KeyboardController()
    private let hotKey = HotKeyMonitor()
    private let loginItem = LoginItemManager()
    private let updateManager = UpdateManager()
    private let calendarManager = CalendarManager()
    private let attachmentExtractor = AttachmentTextExtractor()
    private lazy var toolbarButton = OutlookToolbarButtonController(outlook: outlook)

    private var statusItem: NSStatusItem?
    private var activeSnapshot: OutlookAccessibility.Snapshot?
    private var isRunningFlow = false
    private var isLoadingMail = false
    private var availableUpdate: UpdateManager.AvailableUpdate?
    private var updateMenuItem: NSMenuItem?
    private var requestedMailMode: AppState.OutputMode?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        suppressLegacySettingsWindows()
        DispatchQueue.main.async { [weak self] in self?.suppressLegacySettingsWindows() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.suppressLegacySettingsWindows() }

        migrateExistingAPIKeyIfPossible()
        configureStateActions()
        panel.onClose = { [weak self] in self?.closePanel() }
        configureStatusItem()
        configureHotKey()
        configureToolbarButton()
        configureUpdates()

        _ = loginItem.enableAtLoginIfPossible()

        if keychain.loadAPIKey() == nil {
            state.stage = .apiKey
            panel.show()
        } else {
            state.startupJoke = startupJoke()
            state.stage = .startup
            panel.show(activate: true)
        }

        if !outlook.isTrusted() {
            outlook.requestTrustPrompt()
        }
    }

    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    private func suppressLegacySettingsWindows() {
        for window in NSApp.windows {
            let title = window.title.lowercased()
            if title.contains("replyzen-einstellungen") || title.contains("replyzen settings") {
                window.orderOut(nil)
                window.close()
            }
        }
    }

    private func startupJoke() -> String {
        let jokes = [
            "Warum sind E-Mails schlechte Geheimnisträger? Weil am Ende doch jemand auf ‚Allen antworten‘ klickt.",
            "Mein Kalender wollte spontan sein. Ich habe ihm dafür einen Termin eingetragen.",
            "CC ist die höfliche Art zu sagen: Jetzt weißt du es auch.",
            "Warum war die Mail so entspannt? Sie hatte keinen Anhang zu tragen.",
            "Der kürzeste Büro-Witz? ‚Kurze Abstimmung‘.",
            "Ich wollte meinem Posteingang Urlaub geben. Er hat die Abwesenheitsnotiz abgelehnt.",
            "Warum mag Replyzen Montagmorgen? Weil selbst eine kurze Antwort schon wie Fortschritt aussieht.",
            "Mein Kalender und ich haben eine gute Beziehung: Er sagt mir ständig, wo ich sein soll.",
            "Eine E-Mail ohne Betreff ist wie ein Termin ohne Uhrzeit: spannend, aber unnötig.",
            "Warum hat der Termin nicht zurückgerufen? Er war schon vergeben."
        ]
        return jokes.randomElement() ?? "Replyzen läuft. Das ist heute schon die halbe Miete."
    }

    private func configureStateActions() {
        state.generateAction = { [weak self] in self?.generateCurrentOutput() }
        state.insertAction = { [weak self] in self?.insertGeneratedText() }
        state.createCalendarAction = { [weak self] in self?.createCalendarEvent() }
        state.extractPaymentAction = { [weak self] in self?.generatePaymentSuggestion() }
        state.copyPaymentAction = { [weak self] in self?.copyPaymentDetails() }
        state.connectGoogleCalendarAction = { [weak self] in self?.connectGoogleCalendar() }
        state.disconnectGoogleCalendarAction = { [weak self] in self?.disconnectGoogleCalendar() }
        state.openGoogleCloudAction = { [weak self] in self?.openGoogleCloudCredentials() }
        state.retryAction = { [weak self] in self?.openWorkspace() }
        state.refreshMailAction = { [weak self] in self?.refreshMailContext() }
        state.closeAction = { [weak self] in self?.closePanel() }
        state.saveAPIKeyAction = { [weak self] in self?.saveAPIKey() }
        state.openAccessibilityAction = { [weak self] in self?.openAccessibilitySettings() }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let url = Bundle.main.url(forResource: "ReplyzenLogo", withExtension: "png"),
           let source = NSImage(contentsOf: url),
           let image = makeMenuBarTemplateIcon(from: source) {
            item.button?.image = image
        } else if let fallback = NSImage(systemSymbolName: "envelope.badge", accessibilityDescription: "Replyzen") {
            fallback.isTemplate = true
            item.button?.image = fallback
        }
        item.button?.title = ""
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Replyzen"

        let menu = NSMenu()

        let reply = NSMenuItem(title: "Replyzen öffnen   ⌃⌥R", action: #selector(menuReply), keyEquivalent: "")
        reply.target = self
        menu.addItem(reply)

        let login = NSMenuItem(title: "Bei Anmeldung starten", action: #selector(menuEnableLogin), keyEquivalent: "")
        login.target = self
        menu.addItem(login)

        let key = NSMenuItem(title: "API-Key ändern…", action: #selector(menuAPIKey), keyEquivalent: "")
        key.target = self
        menu.addItem(key)

        menu.addItem(.separator())

        let updates = NSMenuItem(title: "Nach Updates suchen…", action: #selector(menuCheckUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
        updateMenuItem = updates

        let source = NSMenuItem(title: "Update-Quelle…", action: #selector(menuUpdateSource), keyEquivalent: "")
        source.target = self
        menu.addItem(source)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Beenden", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private func makeMenuBarTemplateIcon(from source: NSImage) -> NSImage? {
        let pixels = 36
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
            source.draw(
                in: NSRect(x: 1, y: 1, width: pixels - 2, height: pixels - 2),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return nil }
        let rowBytes = rep.bytesPerRow
        for y in 0..<pixels {
            for x in 0..<pixels {
                let i = y * rowBytes + x * 4
                let r = Int(data[i])
                let g = Int(data[i + 1])
                let b = Int(data[i + 2])
                let originalAlpha = Int(data[i + 3])
                let luminance = (r * 30 + g * 59 + b * 11) / 100
                let darkness = max(0, 255 - luminance)
                let alpha = darkness * originalAlpha / 255
                data[i] = 0
                data[i + 1] = 0
                data[i + 2] = 0
                data[i + 3] = UInt8(alpha)
            }
        }

        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    private func configureHotKey() {
        hotKey.action = { [weak self] in self?.openWorkspace() }
        hotKey.start()
    }

    private func configureToolbarButton() {
        toolbarButton.newAction = { [weak self] in self?.openNewMailWorkspace() }
        toolbarButton.replyAction = { [weak self] in self?.openReplyWorkspace() }
        toolbarButton.declineAction = { [weak self] in self?.quickDecline() }
        toolbarButton.start()
    }

    private func openNewMailWorkspace() {
        requestedMailMode = .newMail
        openWorkspace()
    }

    private func openReplyWorkspace() {
        requestedMailMode = .reply
        openWorkspace()
    }

    private func quickDecline() {
        guard !isRunningFlow else { return }
        guard let apiKey = keychain.loadAPIKey() else {
            openWorkspace()
            return
        }
        guard outlook.isTrusted() else {
            outlook.requestTrustPrompt()
            return
        }

        isRunningFlow = true
        toolbarButton.setSuppressed(true)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            do {
                var snapshot = try self.outlook.captureSnapshot(includeAllWindows: false)
                var mail: String
                do {
                    mail = try self.outlook.readMail(from: snapshot)
                } catch OutlookAccessibility.OutlookError.noMailText {
                    snapshot = try self.outlook.captureSnapshot(includeAllWindows: true)
                    mail = try self.outlook.readMail(from: snapshot)
                }

                self.openAI.generateQuickDecline(apiKey: apiKey, mailText: mail) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        switch result {
                        case .success(let text):
                            let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !reply.isEmpty else {
                                self.isRunningFlow = false
                                self.toolbarButton.setSuppressed(false)
                                self.showSimpleAlert(title: "Absage fehlgeschlagen", message: "OpenAI hat keinen Antworttext geliefert.")
                                return
                            }
                            self.activeSnapshot = snapshot
                            self.insertQuickReply(reply, snapshot: snapshot)
                        case .failure(let error):
                            self.isRunningFlow = false
                            self.toolbarButton.setSuppressed(false)
                            self.showSimpleAlert(title: "Absage fehlgeschlagen", message: error.localizedDescription)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRunningFlow = false
                    self.toolbarButton.setSuppressed(false)
                    self.showSimpleAlert(title: "Absage fehlgeschlagen", message: "Die geöffnete Outlook-Mail konnte nicht gelesen werden.")
                }
            }
        }
    }

    private func insertQuickReply(_ reply: String, snapshot: OutlookAccessibility.Snapshot) {
        copyToPasteboard(reply)
        panel.hide()
        outlook.activateOutlook(pid: snapshot.pid)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.keyboard.sendCommandShiftR()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.copyToPasteboard(reply)
                self.keyboard.sendCommandV()
                self.isRunningFlow = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.toolbarButton.setSuppressed(false)
                }
            }
        }
    }

    @objc private func menuReply() {
        openWorkspace()
    }

    @objc private func menuEnableLogin() {
        if !loginItem.enableAtLoginIfPossible() {
            loginItem.openLoginItemsSettings()
        }
    }

    @objc private func menuAPIKey() {
        toolbarButton.setSuppressed(true)
        state.apiKeyDraft = ""
        state.stage = .apiKey
        panel.show()
    }

    @objc private func menuCheckUpdates() {
        if updateManager.feedURLString.isEmpty {
            configureUpdateSource(showSuccess: false)
            return
        }

        checkForUpdates(interactive: true)
    }

    @objc private func menuUpdateSource() {
        configureUpdateSource(showSuccess: true)
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    private func configureUpdates() {
        guard updateManager.shouldAutoCheck() else { return }
        checkForUpdates(interactive: false)
    }

    private func configureUpdateSource(showSuccess: Bool) {
        let alert = NSAlert()
        brandAlert(alert)
        alert.messageText = "Replyzen · Update-Quelle"
        alert.informativeText = "Replyzen nutzt standardmäßig den offiziellen Update-Kanal. Hier kannst du die HTTPS-Adresse zu update.json bei Bedarf ändern."
        alert.addButton(withTitle: "Speichern")
        alert.addButton(withTitle: "Abbrechen")

        let field = NSTextField(string: updateManager.feedURLString)
        field.placeholderString = "https://…/update.json"
        field.frame = NSRect(x: 0, y: 0, width: 420, height: 24)
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            updateManager.feedURLString = ""
            updateMenuItem?.title = "Nach Updates suchen…"
            return
        }

        guard let url = URL(string: value), url.scheme?.lowercased() == "https" else {
            showSimpleAlert(title: "Ungültige Update-URL", message: "Bitte eine vollständige HTTPS-Adresse zu update.json eintragen.")
            return
        }

        updateManager.feedURLString = value
        if showSuccess {
            showSimpleAlert(title: "Update-Quelle gespeichert", message: "Künftig prüft die App beim Start automatisch auf neue Versionen. Installiert wird erst nach deinem Klick auf „Installieren“. ")
        }
        checkForUpdates(interactive: false)
    }

    private func checkForUpdates(interactive: Bool) {
        updateManager.checkForUpdates { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }

                switch result {
                case .success(let update):
                    self.availableUpdate = update
                    if let update {
                        self.updateMenuItem?.title = "Update verfügbar: \(update.manifest.version)…"
                        if interactive {
                            self.offerUpdate(update)
                        }
                    } else {
                        self.updateMenuItem?.title = "Nach Updates suchen…"
                        if interactive {
                            self.showSimpleAlert(title: "Replyzen", message: "Du verwendest bereits die aktuelle Version \(self.updateManager.currentVersion).")
                        }
                    }
                case .failure(let error):
                    if interactive {
                        self.showSimpleAlert(title: "Update-Prüfung fehlgeschlagen", message: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func offerUpdate(_ update: UpdateManager.AvailableUpdate) {
        let alert = NSAlert()
        brandAlert(alert)
        alert.messageText = "Replyzen \(update.manifest.version) ist verfügbar"
        alert.informativeText = update.manifest.notes?.isEmpty == false
            ? update.manifest.notes!
            : "Die neue Version kann jetzt automatisch geladen und installiert werden."
        alert.addButton(withTitle: "Installieren")
        alert.addButton(withTitle: "Später")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        installUpdate(update)
    }

    private func installUpdate(_ update: UpdateManager.AvailableUpdate) {
        toolbarButton.setSuppressed(true)
        state.stage = .updating
        state.statusText = "Version \(update.manifest.version) wird heruntergeladen"
        panel.show()

        updateManager.install(update) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.state.statusText = "Update ist vorbereitet – App startet gleich neu"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        NSApp.terminate(nil)
                    }
                case .failure(let error):
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func showSimpleAlert(title: String, message: String) {
        let alert = NSAlert()
        brandAlert(alert)
        alert.messageText = title == "Replyzen" ? "Replyzen" : "Replyzen · \(title)"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func brandAlert(_ alert: NSAlert) {
        if let url = Bundle.main.url(forResource: "ReplyzenLogo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 64, height: 64)
            alert.icon = image
        } else {
            alert.icon = NSApp.applicationIconImage
        }
    }

    private func openWorkspace() {
        if isRunningFlow {
            panel.show()
            return
        }

        // One unified Mail form. New and Reply only choose the behavior of the
        // same form. The Outlook overlay can request either mode explicitly.
        if requestedMailMode == .reply {
            state.outputMode = .reply
            state.instruction = defaultReplyInstruction(for: state.replyLanguage)
        } else {
            state.outputMode = .newMail
            state.instruction = ""
        }
        state.instructionHTML = ""
        state.reminderEnabled = false

        guard keychain.loadAPIKey() != nil else {
            toolbarButton.setSuppressed(true)
            state.apiKeyDraft = ""
            state.stage = .apiKey
            panel.show()
            return
        }

        toolbarButton.setSuppressed(true)
        state.stage = .instruction
        panel.show(activate: true)

        refreshMailContext()
    }

    private func detectReplyLanguage(in mailText: String) -> AppState.ReplyLanguage? {
        let cleaned = mailText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 8 else { return nil }

        // The currently opened/latest message is normally at the beginning of the
        // accessibility text. Limiting the sample reduces influence from older quoted
        // messages in long bilingual threads.
        let sample = String(cleaned.prefix(6_000))
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)

        guard let language = recognizer.dominantLanguage else { return nil }
        switch language {
        case .german:
            return .german
        case .english:
            return .usEnglish
        default:
            return nil
        }
    }

    private func defaultReplyInstruction(for language: AppState.ReplyLanguage) -> String {
        switch language {
        case .german:
            return "Kurz, freundlich und direkt antworten."
        case .usEnglish:
            return "Reply briefly, friendly and directly."
        }
    }

    private func isDefaultReplyInstruction(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned == defaultReplyInstruction(for: .german) ||
               cleaned == defaultReplyInstruction(for: .usEnglish)
    }

    private func refreshMailContext() {
        guard !isLoadingMail else { return }

        activeSnapshot = nil
        state.mailText = ""

        guard outlook.isTrusted() else {
            state.outputMode = .newMail
            state.mailStatus = .unavailable("Keine Outlook-Mail verfügbar. Reply ist ausgeblendet.")
            outlook.requestTrustPrompt()
            return
        }

        isLoadingMail = true
        state.mailStatus = .loading

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            do {
                var snapshot = try self.outlook.captureSnapshot(includeAllWindows: false)
                var mail: String

                do {
                    mail = try self.outlook.readMail(from: snapshot)
                } catch OutlookAccessibility.OutlookError.noMailText {
                    snapshot = try self.outlook.captureSnapshot(includeAllWindows: true)
                    mail = try self.outlook.readMail(from: snapshot)
                }

                DispatchQueue.main.async {
                    self.isLoadingMail = false
                    self.activeSnapshot = snapshot
                    self.state.mailText = mail
                    self.state.mailStatus = .available

                    // Respect an explicit New or Reply click from the Outlook overlay.
                    if self.requestedMailMode == .reply {
                        self.state.outputMode = .reply
                    } else if self.requestedMailMode == .newMail {
                        self.state.outputMode = .newMail
                    } else if self.state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                            self.state.instructionHTML = ""
                        }
                        // The lightweight suggestion is selected so typing replaces
                        // it immediately.
                        self.panel.selectInstructionTextSoon()
                    }
                    self.requestedMailMode = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoadingMail = false
                    self.activeSnapshot = nil
                    self.state.mailText = ""

                    let message: String
                    if let outlookError = error as? OutlookAccessibility.OutlookError {
                        switch outlookError {
                        case .notRunning:
                            message = "Outlook läuft gerade nicht. New Mail funktioniert trotzdem."
                        case .noWindow, .noMailText:
                            message = "Keine lesbare Outlook-Mail erkannt. New Mail funktioniert trotzdem."
                        }
                    } else {
                        message = "Mail-Kontext konnte nicht geladen werden. New Mail funktioniert trotzdem."
                    }

                    self.state.mailStatus = .unavailable(message)
                    // No mail context means Reply is not a valid action. Keep the
                    // same form in New Mail and remove only the built-in reply hint.
                    self.state.outputMode = .newMail
                    if self.isDefaultReplyInstruction(self.state.instruction) {
                        self.state.instruction = ""
                        self.state.instructionHTML = ""
                    }
                    self.requestedMailMode = nil
                }
            }
        }
    }

    private func generateCurrentOutput() {
        switch state.outputMode {
        case .reply:
            generateReply()
        case .newMail:
            generateNewMail()
        case .calendar:
            generateCalendarSuggestion()
        case .payment:
            generatePaymentSuggestion()
        }
    }

    private func generateReply() {
        guard let apiKey = keychain.loadAPIKey() else {
            state.stage = .apiKey
            return
        }

        let instruction = state.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        guard !state.mailText.isEmpty else {
            state.mailStatus = .unavailable("Keine lesbare Outlook-Mail erkannt. Nutze New Mail oder versuche es erneut.")
            return
        }

        isRunningFlow = true
        toolbarButton.setSuppressed(true)
        state.stage = .generating
        state.statusText = "OpenAI verarbeitet die Mail"

        openAI.generateReply(
            apiKey: apiKey,
            mailText: state.mailText,
            instruction: instruction,
            instructionHTML: state.instructionHTML,
            tone: state.replyTone,
            language: state.replyLanguage,
            compact: state.newMailCompact
        ) { [weak self] result in
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

        let instruction = state.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }

        isRunningFlow = true
        toolbarButton.setSuppressed(true)
        state.stage = .generating
        state.statusText = "OpenAI formuliert eine neue Mail"

        openAI.generateNewMail(
            apiKey: apiKey,
            instruction: instruction,
            instructionHTML: state.instructionHTML,
            tone: state.replyTone,
            language: state.replyLanguage,
            compact: state.newMailCompact
        ) { [weak self] result in
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

    private func generateCalendarSuggestion() {
        guard let apiKey = keychain.loadAPIKey() else {
            state.stage = .apiKey
            return
        }

        guard !state.mailText.isEmpty else {
            state.mailStatus = .unavailable("Keine lesbare Outlook-Mail erkannt. Für einen Termin bitte eine Mail öffnen und erneut versuchen.")
            return
        }

        isRunningFlow = true
        toolbarButton.setSuppressed(true)
        state.stage = .generating
        state.statusText = "Replyzen erstellt den Terminvorschlag"

        openAI.createCalendarSuggestion(
            apiKey: apiKey,
            mailText: state.mailText,
            language: state.replyLanguage
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunningFlow = false

                switch result {
                case .success(let suggestion):
                    self.state.calendarTitle = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.state.calendarNotes = suggestion.description.trimmingCharacters(in: .whitespacesAndNewlines)
                    let parsedStart = self.parseISODate(suggestion.start)
                    let parsedEnd = self.parseISODate(suggestion.end)

                    if let start = parsedStart {
                        self.state.calendarStart = start
                        self.state.calendarEnd = (parsedEnd != nil && parsedEnd! > start)
                            ? parsedEnd!
                            : start.addingTimeInterval(30 * 60)
                        self.state.calendarWarning = ""
                    } else {
                        let fallback = self.nextRoundedHour()
                        self.state.calendarStart = fallback
                        self.state.calendarEnd = fallback.addingTimeInterval(30 * 60)
                        self.state.calendarWarning = "Im Mailverlauf wurde kein eindeutiger Terminzeitpunkt erkannt. Bitte Datum und Uhrzeit prüfen."
                    }

                    self.state.stage = .calendarPreview
                    self.loadCalendarOptions()
                    self.panel.show()
                case .failure(let error):
                    self.showError(error.localizedDescription)
                }
            }
        }
    }


    private func generatePaymentSuggestion() {
        guard let apiKey = keychain.loadAPIKey() else {
            state.stage = .apiKey
            return
        }
        guard !state.mailText.isEmpty, let snapshot = activeSnapshot else {
            state.mailStatus = .unavailable("Keine lesbare Outlook-Mail erkannt. Für eine Überweisung bitte die Rechnungsmail öffnen und erneut versuchen.")
            return
        }

        isRunningFlow = true
        toolbarButton.setSuppressed(true)
        state.stage = .generating
        state.statusText = "Replyzen sucht den PDF-Anhang …"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let filenames = self.outlook.attachmentFilenames(from: snapshot)
            let mentionedPDF = filenames.first { $0.lowercased().hasSuffix(".pdf") }

            var directFiles = self.outlook.attachmentFileURLs(from: snapshot)
            var resolvedFiles = directFiles + self.attachmentExtractor.resolveFiles(filenames: filenames)
            var selectedPDFs = Array(resolvedFiles.filter { $0.pathExtension.lowercased() == "pdf" }.prefix(3))

            if selectedPDFs.isEmpty, let pdfName = mentionedPDF {
                DispatchQueue.main.sync {
                    self.state.statusText = "PDF wird aus Outlook geladen …"
                    self.outlook.activateOutlook(pid: snapshot.pid)
                    _ = self.outlook.activateAttachment(named: pdfName, from: snapshot)
                }

                Thread.sleep(forTimeInterval: 1.4)
                let retrySnapshot = (try? self.outlook.captureSnapshot(includeAllWindows: true)) ?? snapshot
                directFiles = self.outlook.attachmentFileURLs(from: retrySnapshot)
                resolvedFiles = directFiles + self.attachmentExtractor.resolveFiles(filenames: filenames)
                selectedPDFs = Array(resolvedFiles.filter { $0.pathExtension.lowercased() == "pdf" }.prefix(3))
            }

            var fallbackText = ""
            var sourceStatus: String

            if !selectedPDFs.isEmpty {
                sourceStatus = "PDF direkt mit OpenAI gelesen: " + selectedPDFs.map(\.lastPathComponent).joined(separator: ", ")
                DispatchQueue.main.async {
                    self.state.statusText = "PDF wird direkt an OpenAI übergeben und gelesen …"
                }
            } else {
                let fallback = self.attachmentExtractor.extract(filenames: filenames)
                fallbackText = fallback.text

                let pdfMentioned = filenames.contains { $0.lowercased().hasSuffix(".pdf") }
                if !fallback.usedFiles.isEmpty {
                    sourceStatus = "Kein direkt zugängliches PDF; lokal gelesen: " + fallback.usedFiles.joined(separator: ", ")
                } else if pdfMentioned {
                    sourceStatus = "PDF-Anhang erkannt, aber Outlook hat keine lokale Datei bereitgestellt. Bitte den PDF-Anhang einmal in Outlook öffnen und erneut auf Überweisung klicken."
                } else {
                    sourceStatus = "Kein PDF-Anhang erkannt. Extraktion aus dem Mailtext."
                }
                DispatchQueue.main.async {
                    self.state.statusText = sourceStatus
                }
            }

            self.openAI.createPaymentSuggestion(
                apiKey: apiKey,
                mailText: self.state.mailText,
                fileURLs: selectedPDFs,
                fallbackAttachmentText: fallbackText
            ) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRunningFlow = false

                    switch result {
                    case .success(let suggestion):
                        self.state.paymentRecipient = suggestion.recipient?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        self.state.paymentIBAN = suggestion.iban?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        self.state.paymentBIC = suggestion.bic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        self.state.paymentAmount = suggestion.amount?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        self.state.paymentCurrency = suggestion.currency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "EUR"
                        self.state.paymentPurpose = suggestion.purpose?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        self.state.paymentSourceStatus = sourceStatus

                        let confidence = suggestion.confidence?.lowercased() ?? "low"
                        let missingCore = self.state.paymentRecipient.isEmpty || self.state.paymentIBAN.isEmpty || self.state.paymentAmount.isEmpty
                        if selectedPDFs.isEmpty {
                            self.state.paymentWarning = "Kein PDF wurde direkt von OpenAI gelesen. Bitte Empfänger, IBAN und Betrag besonders sorgfältig prüfen."
                        } else if confidence == "low" || missingCore {
                            self.state.paymentWarning = "Die Extraktion ist nicht eindeutig. Bitte die PDF-Rechnung mit den Feldern unten vergleichen."
                        } else {
                            self.state.paymentWarning = "Bitte IBAN, Betrag und Verwendungszweck vor einer Überweisung immer mit der PDF-Rechnung vergleichen."
                        }

                        self.state.stage = .paymentPreview
                        self.panel.show()
                    case .failure(let error):
                        self.showError(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func copyPaymentDetails() {
        let lines = [
            state.paymentRecipient.isEmpty ? nil : "Empfänger: \(state.paymentRecipient)",
            state.paymentIBAN.isEmpty ? nil : "IBAN: \(state.paymentIBAN)",
            state.paymentBIC.isEmpty ? nil : "BIC: \(state.paymentBIC)",
            state.paymentAmount.isEmpty ? nil : "Betrag: \(state.paymentAmount) \(state.paymentCurrency)",
            state.paymentPurpose.isEmpty ? nil : "Verwendungszweck: \(state.paymentPurpose)"
        ].compactMap { $0 }
        guard !lines.isEmpty else { return }
        copyToPasteboard(lines.joined(separator: "\n"))
        state.successMessage = "Überweisungsdaten wurden in die Zwischenablage kopiert. Bitte vor der Zahlung im Banking prüfen."
        state.stage = .success
        panel.show()
    }

    private func createCalendarEvent() {
        let title = state.calendarTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        guard state.calendarEnd > state.calendarStart else {
            showError("Die Endzeit muss nach der Startzeit liegen.")
            return
        }

        guard !state.selectedCalendarID.isEmpty else {
            showError("Bitte zuerst einen Kalender auswählen.")
            return
        }
        UserDefaults.standard.set(state.selectedCalendarID, forKey: "Replyzen.SelectedMinuboCalendarID")

        isRunningFlow = true
        toolbarButton.setSuppressed(true)
        state.stage = .generating
        state.statusText = "Termin wird direkt in Google Calendar angelegt"

        let selectedCalendarName = state.calendarOptions.first(where: { $0.id == state.selectedCalendarID })?.title ?? "Kalender"
        calendarManager.createEvent(
            title: title,
            notes: state.calendarNotes,
            start: state.calendarStart,
            end: state.calendarEnd,
            calendarIdentifier: state.selectedCalendarID
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunningFlow = false
                switch result {
                case .success:
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "de_DE")
                    formatter.timeZone = CalendarManager.eventTimeZone
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .short
                    self.state.successMessage = "„\(title)“ wurde am \(formatter.string(from: self.state.calendarStart)) direkt in Google Calendar · „\(selectedCalendarName)“ angelegt."
                    self.state.stage = .success
                    self.panel.show()
                case .failure(let error):
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func loadCalendarOptions() {
        state.calendarOptions = []
        state.selectedCalendarID = ""
        state.googleConnectedEmail = calendarManager.connectedEmail() ?? ""

        guard calendarManager.isConfigured() else {
            state.googleNeedsOAuthCredentials = true
            state.googleOAuthStatus = "Einmalig Google OAuth einrichten."
            state.calendarListStatus = "Google Calendar ist noch nicht verbunden."
            return
        }

        state.googleNeedsOAuthCredentials = false
        guard let email = calendarManager.connectedEmail() else {
            state.googleOAuthStatus = "Noch nicht mit Google verbunden."
            state.calendarListStatus = "Bitte mit lennard@minubo.com verbinden."
            return
        }

        guard email.caseInsensitiveCompare(CalendarManager.targetEmail) == .orderedSame else {
            calendarManager.disconnect()
            state.googleConnectedEmail = ""
            state.googleOAuthStatus = "Bitte mit lennard@minubo.com verbinden."
            state.calendarListStatus = "Falsches Google-Konto."
            return
        }

        state.googleConnectedEmail = email
        state.googleOAuthStatus = "Verbunden mit \(email)"
        state.calendarListStatus = "Google-Kalender werden geladen …"

        calendarManager.loadCalendarOptions { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let options):
                    self.state.calendarOptions = options
                    if options.isEmpty {
                        self.state.selectedCalendarID = ""
                        self.state.calendarListStatus = "Keine beschreibbaren Google-Kalender gefunden."
                        return
                    }

                    let savedID = UserDefaults.standard.string(forKey: "Replyzen.SelectedMinuboCalendarID") ?? ""
                    if options.contains(where: { $0.id == savedID }) {
                        self.state.selectedCalendarID = savedID
                    } else if let preferred = options.first(where: { $0.title.lowercased() == "minubo" }) {
                        self.state.selectedCalendarID = preferred.id
                    } else {
                        self.state.selectedCalendarID = options[0].id
                    }
                    self.state.calendarListStatus = ""
                case .failure(let error):
                    self.state.selectedCalendarID = ""
                    self.state.calendarListStatus = error.localizedDescription
                    self.state.googleOAuthStatus = error.localizedDescription
                }
            }
        }
    }

    private func connectGoogleCalendar() {
        let clientID = state.googleClientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = state.googleClientSecretDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        if !calendarManager.isConfigured() && (clientID.isEmpty || clientSecret.isEmpty) {
            state.googleNeedsOAuthCredentials = true
            state.googleOAuthStatus = "Bitte Client-ID und Client Secret eintragen."
            return
        }

        state.googleIsConnecting = true
        state.googleOAuthStatus = "Google-Anmeldung wird im Browser geöffnet …"

        calendarManager.connect(clientID: clientID, clientSecret: clientSecret) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.state.googleIsConnecting = false
                switch result {
                case .success(let email):
                    self.state.googleConnectedEmail = email
                    self.state.googleNeedsOAuthCredentials = false
                    self.state.googleClientSecretDraft = ""
                    self.state.googleOAuthStatus = "Verbunden mit \(email)"
                    self.loadCalendarOptions()
                case .failure(let error):
                    self.state.googleOAuthStatus = error.localizedDescription
                    self.state.calendarListStatus = error.localizedDescription
                }
            }
        }
    }

    private func disconnectGoogleCalendar() {
        calendarManager.disconnect()
        state.googleConnectedEmail = ""
        state.calendarOptions = []
        state.selectedCalendarID = ""
        state.googleOAuthStatus = "Google Calendar wurde getrennt."
        state.calendarListStatus = "Bitte erneut mit lennard@minubo.com verbinden."
    }

    private func openGoogleCloudCredentials() {
        if let url = URL(string: "https://console.cloud.google.com/apis/credentials") {
            NSWorkspace.shared.open(url)
        }
    }

    private func parseISODate(_ value: String?) -> Date? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func nextRoundedHour() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = CalendarManager.eventTimeZone
        let now = Date().addingTimeInterval(60 * 60)
        var components = calendar.dateComponents([.year, .month, .day, .hour], from: now)
        components.minute = 0
        components.second = 0
        return calendar.date(from: components) ?? now
    }

    private func reminderBCCAddress() -> String? {
        guard state.reminderEnabled else { return nil }
        let day = state.reminderDay.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let time = state.reminderTime.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["mon", "tue", "wed", "thu", "fri", "sat", "sun"].contains(day), !time.isEmpty else { return nil }
        return "\(day)\(time)@fut.io"
    }

    private func insertGeneratedText() {
        switch state.outputMode {
        case .reply:
            insertReply()
        case .newMail:
            insertNewMail()
        case .calendar, .payment:
            break
        }
    }

    private func insertReply() {
        guard let snapshot = activeSnapshot else {
            state.stage = .instruction
            state.mailStatus = .unavailable("Die ursprüngliche Outlook-Mail ist nicht mehr verfügbar. Bitte erneut laden.")
            return
        }

        let reply = state.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return }

        guard outlook.isTrusted() else {
            copyMailToPasteboard(plainText: reply, html: state.replyHTML)
            showError("Replyzen braucht Bedienungshilfen, um den Text automatisch in Outlook einzusetzen. Der Text wurde in die Zwischenablage kopiert.")
            return
        }

        state.stage = .inserting
        state.statusText = "Outlook wird aktiviert"
        isRunningFlow = true
        toolbarButton.setSuppressed(true)

        copyMailToPasteboard(plainText: reply, html: state.replyHTML)
        panel.hide()
        outlook.activateOutlook(pid: snapshot.pid)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.keyboard.sendCommandShiftR()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in
                guard let self else { return }
                if let reminder = self.reminderBCCAddress() {
                    _ = self.outlook.setComposeBCCValue(reminder)
                    _ = self.outlook.focusComposeBodyField()
                    self.copyMailToPasteboard(plainText: reply, html: self.state.replyHTML)
                }
                self.keyboard.sendCommandV()
                self.isRunningFlow = false
                self.state.stage = .idle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.toolbarButton.setSuppressed(false)
                }
            }
        }
    }

    private func insertNewMail() {
        let subject = state.newMailSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = state.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let html = state.replyHTML
        guard !body.isEmpty else { return }

        guard let pid = outlook.runningPID() else {
            copyMailToPasteboard(plainText: body, html: html)
            showError("Microsoft Outlook läuft nicht. Der Mailtext wurde in die Zwischenablage kopiert.")
            return
        }

        guard outlook.isTrusted() else {
            copyMailToPasteboard(plainText: body, html: html)
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
            self?.populateNewMailDraft(subject: subject, body: body, html: html, attempt: 0)
        }
    }

    private func populateNewMailDraft(subject: String, body: String, html: String, attempt: Int) {
        let delay = attempt == 0 ? 0.8 : 0.22
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }

            let subjectDone = subject.isEmpty || self.outlook.setComposeSubjectValue(subject)
            let reminderDone: Bool
            if let reminder = self.reminderBCCAddress() {
                reminderDone = self.outlook.setComposeBCCValue(reminder)
            } else {
                reminderDone = true
            }
            // Accessibility can set plain text directly, but rich formatting must be
            // pasted from the HTML/RTF clipboard. Keep the direct path only when
            // no rich HTML has been produced.
            if html.isEmpty, reminderDone, self.outlook.setComposeBodyValue(body) {
                self.finishNewMailInsertion()
                return
            }

            // Give Outlook a short moment to finish constructing the compose window, but do not wait for many retries.
            if attempt < 2 {
                self.populateNewMailDraft(subject: subject, body: body, html: html, attempt: attempt + 1)
                return
            }

            if !reminderDone, let reminder = self.reminderBCCAddress() {
                _ = self.outlook.setComposeBCCValue(reminder)
            }

            var subjectReady = subjectDone
            if !subjectReady, self.outlook.focusComposeSubjectField() {
                self.copyToPasteboard(subject)
                self.keyboard.sendCommandV()
                subjectReady = true
            }

            // Classic Outlook exposes the subject reliably but often does not expose the HTML body as a settable AXTextArea.
            // From the subject field, one Tab moves the caret into the message body much more reliably.
            if subjectReady, self.outlook.focusComposeSubjectField() {
                self.keyboard.sendTab()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                    guard let self else { return }
                    self.copyMailToPasteboard(plainText: body, html: html)
                    self.keyboard.sendCommandV()
                    self.finishNewMailInsertion()
                }
                return
            }

            if self.outlook.focusComposeBodyField() {
                self.copyMailToPasteboard(plainText: body, html: html)
                self.keyboard.sendCommandV()
                self.finishNewMailInsertion()
            } else {
                self.copyMailToPasteboard(plainText: body, html: html)
                self.isRunningFlow = false
                self.showError("Der Mailtext konnte nicht automatisch eingesetzt werden. Er liegt in der Zwischenablage.")
            }
        }
    }

    private func finishNewMailInsertion() {
        isRunningFlow = false
        state.stage = .idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.toolbarButton.setSuppressed(false)
        }
    }

    private func copyMailToPasteboard(plainText: String, html: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(plainText, forType: .string)

        let cleanedHTML = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedHTML.isEmpty, let htmlData = cleanedHTML.data(using: .utf8) else { return }
        pasteboard.setData(htmlData, forType: .html)

        if let attributed = try? NSAttributedString(
            data: htmlData,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ),
           let rtf = try? attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
           ) {
            pasteboard.setData(rtf, forType: .rtf)
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveAPIKey() {
        let key = state.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        if keychain.saveAPIKey(key) {
            state.apiKeyDraft = ""
            state.stage = .instruction
            openWorkspace()
        } else {
            showError("Der API-Key konnte nicht im macOS-Schlüsselbund gespeichert werden.")
        }
    }

    private func closePanel() {
        isRunningFlow = false
        state.stage = .idle
        panel.hide()
        toolbarButton.setSuppressed(false)
    }

    private func showError(_ message: String) {
        isRunningFlow = false
        state.errorMessage = message
        state.stage = .error
        toolbarButton.setSuppressed(true)
        panel.show()
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func migrateExistingAPIKeyIfPossible() {
        guard keychain.loadAPIKey() == nil else { return }

        let path = NSString(string: "~/Downloads/LennardOutlookAI/.env").expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("OPENAI_API_KEY=") else { continue }
            let key = String(line.dropFirst("OPENAI_API_KEY=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                _ = keychain.saveAPIKey(key)
                return
            }
        }
    }
}
