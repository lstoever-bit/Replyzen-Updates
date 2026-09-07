import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private let commandStore = CommandStore()
    private lazy var panel = FloatingPanelController(state: state, commands: commandStore)
    private let outlook = OutlookAccessibility()
    private let openAI = OpenAIClient()
    private let keychain = KeychainStore()
    private let keyboard = KeyboardController()
    private let hotKey = HotKeyMonitor()
    private let loginItem = LoginItemManager()
    private let updateManager = UpdateManager()
    private let calendarManager = CalendarManager()
    private lazy var toolbarButton = OutlookToolbarButtonController(outlook: outlook)

    private var statusItem: NSStatusItem?
    private var activeSnapshot: OutlookAccessibility.Snapshot?
    private var isRunningFlow = false
    private var isLoadingMail = false
    private var availableUpdate: UpdateManager.AvailableUpdate?
    private var updateMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

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
            state.stage = .idle
        }

        if !outlook.isTrusted() {
            outlook.requestTrustPrompt()
        }
    }

    private func configureStateActions() {
        state.generateAction = { [weak self] in self?.generateCurrentOutput() }
        state.insertAction = { [weak self] in self?.insertGeneratedText() }
        state.createCalendarAction = { [weak self] in self?.createCalendarEvent() }
        state.retryAction = { [weak self] in self?.openWorkspace() }
        state.refreshMailAction = { [weak self] in self?.refreshMailContext() }
        state.closeAction = { [weak self] in self?.closePanel() }
        state.saveAPIKeyAction = { [weak self] in self?.saveAPIKey() }
        state.openAccessibilityAction = { [weak self] in self?.openAccessibilitySettings() }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Replyzen")

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

    private func configureHotKey() {
        hotKey.action = { [weak self] in self?.openWorkspace() }
        hotKey.start()
    }

    private func configureToolbarButton() {
        toolbarButton.action = { [weak self] in self?.openWorkspace() }
        toolbarButton.start()
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
        alert.messageText = "Update-Quelle"
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
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func openWorkspace() {
        if isRunningFlow {
            panel.show()
            return
        }

        guard keychain.loadAPIKey() != nil else {
            toolbarButton.setSuppressed(true)
            state.apiKeyDraft = ""
            state.stage = .apiKey
            panel.show()
            return
        }

        toolbarButton.setSuppressed(true)
        prepareDefaultCommandIfNeeded()
        state.stage = .instruction
        panel.show(activate: true)

        refreshMailContext()
    }

    private func prepareDefaultCommandIfNeeded() {
        guard state.outputMode == .reply else { return }
        let trimmed = state.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return }

        if let command = commandStore.commands.first {
            state.instruction = command.prompt
            state.replyTone = command.tone
            state.selectedCommandName = command.name
        } else {
            state.instruction = ""
            state.replyTone = .friendly
            state.selectedCommandName = "Custom"
        }
    }

    private func refreshMailContext() {
        guard !isLoadingMail else { return }

        activeSnapshot = nil
        state.mailText = ""

        guard outlook.isTrusted() else {
            state.mailStatus = .unavailable("Outlook-Zugriff ist noch nicht freigegeben. New Mail funktioniert trotzdem.")
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
            tone: state.replyTone,
            language: state.replyLanguage
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunningFlow = false

                switch result {
                case .success(let text):
                    self.state.reply = text
                    self.state.stage = .preview
                    self.panel.show()
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
            tone: state.replyTone,
            language: state.replyLanguage
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunningFlow = false

                switch result {
                case .success(let text):
                    self.state.reply = text
                    self.state.stage = .preview
                    self.panel.show()
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
        state.statusText = "Termin wird im ausgewählten Kalender angelegt"

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
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .short
                    self.state.successMessage = "„\(title)“ wurde am \(formatter.string(from: self.state.calendarStart)) im Kalender „\(selectedCalendarName)“ angelegt."
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
        state.calendarListStatus = "Kalender werden geladen …"

        calendarManager.loadCalendarOptions { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let options):
                    self.state.calendarOptions = options
                    if options.isEmpty {
                        self.state.selectedCalendarID = ""
                        self.state.calendarListStatus = "Keine beschreibbaren minubo-Kalender gefunden."
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
                }
            }
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
        let calendar = Calendar.current
        let now = Date().addingTimeInterval(60 * 60)
        var components = calendar.dateComponents([.year, .month, .day, .hour], from: now)
        components.minute = 0
        components.second = 0
        return calendar.date(from: components) ?? now
    }

    private func insertGeneratedText() {
        switch state.outputMode {
        case .reply:
            insertReply()
        case .newMail:
            insertNewMail()
        case .calendar:
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
            copyToPasteboard(reply)
            showError("Replyzen braucht Bedienungshilfen, um den Text automatisch in Outlook einzusetzen. Der Text wurde in die Zwischenablage kopiert.")
            return
        }

        state.stage = .inserting
        state.statusText = "Outlook wird aktiviert"
        isRunningFlow = true
        toolbarButton.setSuppressed(true)

        copyToPasteboard(reply)
        panel.hide()
        outlook.activateOutlook(pid: snapshot.pid)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.keyboard.sendCommandR()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in
                guard let self else { return }
                self.keyboard.sendCommandV()
                self.isRunningFlow = false
                self.state.stage = .success
                self.panel.show()
            }
        }
    }

    private func insertNewMail() {
        let text = state.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard let pid = outlook.runningPID() else {
            copyToPasteboard(text)
            showError("Microsoft Outlook läuft nicht. Der Mailtext wurde in die Zwischenablage kopiert.")
            return
        }

        guard outlook.isTrusted() else {
            copyToPasteboard(text)
            outlook.requestTrustPrompt()
            showError("Replyzen braucht Bedienungshilfen, um automatisch eine neue Outlook-Mail zu öffnen. Der Text wurde in die Zwischenablage kopiert.")
            return
        }

        state.stage = .inserting
        state.statusText = "Neue Outlook-Mail wird geöffnet"
        isRunningFlow = true
        toolbarButton.setSuppressed(true)

        copyToPasteboard(text)
        panel.hide()
        outlook.activateOutlook(pid: pid)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.keyboard.sendCommandN()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.keyboard.sendCommandV()
                self.isRunningFlow = false
                self.state.stage = .success
                self.panel.show()
            }
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
