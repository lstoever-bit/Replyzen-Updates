import AppKit
import SwiftUI
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

    private var languageObserver: NSObjectProtocol?
    private var languageSettingsWindow: NSWindow?

    private var statusItem: NSStatusItem?
    private var activeSnapshot: OutlookAccessibility.Snapshot?
    private var isRunningFlow = false
    private var isLoadingMail = false
    private var availableUpdate: UpdateManager.AvailableUpdate?
    private var updateMenuItem: NSMenuItem?
    private var requestedMailMode: AppState.OutputMode?
    private var outlookLaunchObserver: NSObjectProtocol?
    private var outlookTerminateObserver: NSObjectProtocol?
    private var outlookSessionActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        suppressLegacySettingsWindows()
        DispatchQueue.main.async { [weak self] in self?.suppressLegacySettingsWindows() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.suppressLegacySettingsWindows() }

        migrateExistingAPIKeyIfPossible()
        _ = AppLocalization.shared
        languageObserver = NotificationCenter.default.addObserver(
            forName: .replyZenLanguageDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshInterfaceLanguage() }
        configureStateActions()
        panel.onClose = { [weak self] in self?.closePanel() }
        configureHotKey()
        configureToolbarButton()
        configureUpdates()
        configureOutlookLifecycle()

        // The login item is intentionally kept as a silent watcher. Without a tiny
        // background process macOS could not relaunch Replyzen exactly when Outlook
        // opens. No Replyzen UI is shown while Outlook is closed.
        _ = loginItem.enableAtLoginIfPossible()

        if isOutlookRunning {
            activateForOutlook()
        } else {
            deactivateForOutlook()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let center = NSWorkspace.shared.notificationCenter
        if let outlookLaunchObserver { center.removeObserver(outlookLaunchObserver) }
        if let outlookTerminateObserver { center.removeObserver(outlookTerminateObserver) }
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
        toolbarButton.stop()
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
            L10n.source("Warum sind E-Mails schlechte Geheimnisträger? Weil am Ende doch jemand auf ‚Allen antworten‘ klickt."),
            L10n.source("Mein Kalender wollte spontan sein. Ich habe ihm dafür einen Termin eingetragen."),
            L10n.source("CC ist die höfliche Art zu sagen: Jetzt weißt du es auch."),
            L10n.source("Warum war die Mail so entspannt? Sie hatte keinen Anhang zu tragen."),
            L10n.source("Der kürzeste Büro-Witz? ‚Kurze Abstimmung‘."),
            L10n.source("Ich wollte meinem Posteingang Urlaub geben. Er hat die Abwesenheitsnotiz abgelehnt."),
            L10n.source("Warum mag Replyzen Montagmorgen? Weil selbst eine kurze Antwort schon wie Fortschritt aussieht."),
            L10n.source("Mein Kalender und ich haben eine gute Beziehung: Er sagt mir ständig, wo ich sein soll."),
            L10n.source("Eine E-Mail ohne Betreff ist wie ein Termin ohne Uhrzeit: spannend, aber unnötig."),
            L10n.source("Warum hat der Termin nicht zurückgerufen? Er war schon vergeben.")
        ]
        return jokes.randomElement() ?? L10n.source("Replyzen läuft. Das ist heute schon die halbe Miete.")
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
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = ReplyZenBrand.menuBarIcon {
            item.button?.image = image
        } else if let fallback = NSImage(systemSymbolName: "envelope.badge", accessibilityDescription: ReplyZenBrand.displayName) {
            fallback.isTemplate = true
            item.button?.image = fallback
        }
        item.button?.title = ""
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = ReplyZenBrand.displayName

        let menu = NSMenu()

        let reply = NSMenuItem(title: L10n.tr("ReplyZen öffnen   ⌃⌥R"), action: #selector(menuReply), keyEquivalent: "")
        reply.target = self
        menu.addItem(reply)

        let settings = NSMenuItem(title: L10n.tr("Einstellungen…"), action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let login = NSMenuItem(title: L10n.tr("Bei Anmeldung starten"), action: #selector(menuEnableLogin), keyEquivalent: "")
        login.target = self
        menu.addItem(login)

        let key = NSMenuItem(title: L10n.tr("API-Key ändern…"), action: #selector(menuAPIKey), keyEquivalent: "")
        key.target = self
        menu.addItem(key)

        menu.addItem(.separator())

        let updates = NSMenuItem(title: L10n.tr("Nach Updates suchen…"), action: #selector(menuCheckUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
        updateMenuItem = updates

        let source = NSMenuItem(title: L10n.tr("Update-Quelle…"), action: #selector(menuUpdateSource), keyEquivalent: "")
        source.target = self
        menu.addItem(source)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L10n.tr("Beenden"), action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private func configureHotKey() {
        hotKey.action = { [weak self] in
            guard let self, self.isOutlookRunning else { return }
            self.openWorkspace()
        }
        hotKey.start()
    }

    private func configureToolbarButton() {
        toolbarButton.newAction = { [weak self] in self?.openNewMailWorkspace() }
        toolbarButton.replyAction = { [weak self] in self?.openReplyWorkspace(replyAll: false) }
        toolbarButton.replyAllAction = { [weak self] in self?.openReplyWorkspace(replyAll: true) }
        toolbarButton.forwardAction = { [weak self] in self?.openForwardWorkspace() }
        toolbarButton.cancelAction = { [weak self] in self?.quickDecline() }
        toolbarButton.calendarAction = { [weak self] in self?.createCalendarFromOverlay() }
        toolbarButton.paymentAction = { [weak self] in self?.createPaymentFromOverlay() }
    }

    private var isOutlookRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.microsoft.Outlook" }
    }

    private func configureOutlookLifecycle() {
        let center = NSWorkspace.shared.notificationCenter

        outlookLaunchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.microsoft.Outlook" else { return }
            self.activateForOutlook()
        }

        outlookTerminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.microsoft.Outlook" else { return }
            self.deactivateForOutlook()
        }
    }

    private func activateForOutlook() {
        guard !outlookSessionActive else { return }
        outlookSessionActive = true
        configureStatusItem()
        toolbarButton.setSuppressed(false)
        toolbarButton.start()

        if !outlook.isTrusted() {
            outlook.requestTrustPrompt()
        }

        // Do not pop up the old startup window every time Outlook launches. The
        // menu-bar icon and Outlook overlay are the visible Replyzen surface. Only
        // first-time API-key setup needs a panel automatically.
        if keychain.loadAPIKey() == nil {
            state.stage = .apiKey
            panel.show()
        } else {
            state.stage = .idle
            panel.hide()
        }
    }

    private func deactivateForOutlook() {
        outlookSessionActive = false
        isRunningFlow = false
        isLoadingMail = false
        activeSnapshot = nil
        panel.hide()
        toolbarButton.stop()

        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func openNewMailWorkspace() {
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

    private func createCalendarFromOverlay() {
        guard !isRunningFlow else { return }
        guard let apiKey = keychain.loadAPIKey() else {
            toolbarButton.setSuppressed(true)
            state.apiKeyDraft = ""
            state.stage = .apiKey
            panel.show()
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

                DispatchQueue.main.async {
                    self.activeSnapshot = snapshot
                    self.state.mailText = mail
                    self.state.mailStatus = .available
                    self.state.outputMode = .calendar
                    if let language = self.detectReplyLanguage(in: mail) {
                        self.state.replyLanguage = language
                    }
                    // Keep the panel hidden while OpenAI works. The existing
                    // calendar generator opens only the result window on success.
                    self.generateCalendarSuggestion(apiKey: apiKey)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRunningFlow = false
                    self.toolbarButton.setSuppressed(false)
                    self.showSimpleAlert(
                        title: L10n.source("Termin nicht erstellt"),
                        message: L10n.source("Die geöffnete Outlook-Mail konnte nicht gelesen werden.")
                    )
                }
            }
        }
    }

    private func createPaymentFromOverlay() {
        guard !isRunningFlow else { return }
        // Warm/load the API key before starting the hidden flow. KeychainStore caches
        // it for the rest of the app session, so the extractor can reuse it.
        guard keychain.loadAPIKey() != nil else {
            toolbarButton.setSuppressed(true)
            state.apiKeyDraft = ""
            state.stage = .apiKey
            panel.show()
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

                var paymentSnapshot = snapshot
                var paymentMail = mail

                // Legacy Outlook exposes attachment files more reliably once the
                // selected mail is opened in its own message window.
                DispatchQueue.main.sync {
                    paymentSnapshot = self.outlook.openSelectedMessageWindowIfNeeded(from: snapshot)
                }
                if let refreshedMail = try? self.outlook.readMail(from: paymentSnapshot),
                   !refreshedMail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    paymentMail = refreshedMail
                }

                DispatchQueue.main.async {
                    self.activeSnapshot = paymentSnapshot
                    self.state.mailText = paymentMail
                    self.state.mailStatus = .available
                    self.state.outputMode = .payment
                    // Do not show the normal Replyzen form. The existing extractor
                    // opens only the editable payment result window when finished.
                    self.generatePaymentSuggestion()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRunningFlow = false
                    self.toolbarButton.setSuppressed(false)
                    self.showSimpleAlert(
                        title: L10n.source("Überweisung nicht erkannt"),
                        message: L10n.source("Die geöffnete Outlook-Mail konnte nicht gelesen werden.")
                    )
                }
            }
        }
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
                                self.showSimpleAlert(title: L10n.source("Absage fehlgeschlagen"), message: L10n.source("OpenAI hat keinen Antworttext geliefert."))
                                return
                            }
                            self.activeSnapshot = snapshot
                            self.insertQuickReply(reply, snapshot: snapshot)
                        case .failure(let error):
                            self.isRunningFlow = false
                            self.toolbarButton.setSuppressed(false)
                            self.showSimpleAlert(title: L10n.source("Absage fehlgeschlagen"), message: error.localizedDescription)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRunningFlow = false
                    self.toolbarButton.setSuppressed(false)
                    self.showSimpleAlert(title: L10n.source("Absage fehlgeschlagen"), message: L10n.source("Die geöffnete Outlook-Mail konnte nicht gelesen werden."))
                }
            }
        }
    }

    private func insertQuickReply(_ reply: String, snapshot: OutlookAccessibility.Snapshot) {
        copyMailToPasteboard(plainText: reply, html: "")
        panel.hide()
        outlook.activateOutlook(pid: snapshot.pid)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.keyboard.sendCommandShiftR()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.copyMailToPasteboard(plainText: reply, html: "")
                self.keyboard.sendCommandV()
                self.isRunningFlow = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.toolbarButton.setSuppressed(false)
                }
            }
        }
    }

    @objc private func menuSettings() {
        if languageSettingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 250),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: InterfaceSettingsView())
            window.center()
            languageSettingsWindow = window
        }
        languageSettingsWindow?.title = L10n.tr("Einstellungen")
        languageSettingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshInterfaceLanguage() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            configureStatusItem()
            if let update = availableUpdate {
                updateMenuItem?.title = L10n.tr("Update verfügbar: {0}…", update.manifest.version)
            }
        }
        toolbarButton.refreshLocalization()
        languageSettingsWindow?.title = L10n.tr("Einstellungen")
        state.objectWillChange.send()
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
        alert.messageText = L10n.tr("Replyzen · Update-Quelle")
        alert.informativeText = L10n.tr("Replyzen nutzt standardmäßig den offiziellen Update-Kanal. Hier kannst du die HTTPS-Adresse zu update.json bei Bedarf ändern.")
        alert.addButton(withTitle: L10n.tr("Speichern"))
        alert.addButton(withTitle: L10n.tr("Abbrechen"))

        let field = NSTextField(string: updateManager.feedURLString)
        field.placeholderString = "https://…/update.json"
        field.frame = NSRect(x: 0, y: 0, width: 420, height: 24)
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            updateManager.feedURLString = ""
            updateMenuItem?.title = L10n.tr("Nach Updates suchen…")
            return
        }

        guard let url = URL(string: value), url.scheme?.lowercased() == "https" else {
            showSimpleAlert(title: L10n.source("Ungültige Update-URL"), message: L10n.source("Bitte eine vollständige HTTPS-Adresse zu update.json eintragen."))
            return
        }

        updateManager.feedURLString = value
        if showSuccess {
            showSimpleAlert(title: L10n.source("Update-Quelle gespeichert"), message: L10n.source("Künftig prüft die App beim Start automatisch auf neue Versionen. Installiert wird erst nach deinem Klick auf „Installieren“. "))
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
                        self.updateMenuItem?.title = L10n.tr("Update verfügbar: {0}…", update.manifest.version)
                        if interactive {
                            self.offerUpdate(update)
                        }
                    } else {
                        self.updateMenuItem?.title = L10n.tr("Nach Updates suchen…")
                        if interactive {
                            self.showSimpleAlert(title: "Replyzen", message: L10n.source("Du verwendest bereits die aktuelle Version {0}.", self.updateManager.currentVersion))
                        }
                    }
                case .failure(let error):
                    if interactive {
                        self.showSimpleAlert(title: L10n.source("Update-Prüfung fehlgeschlagen"), message: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func offerUpdate(_ update: UpdateManager.AvailableUpdate) {
        let alert = NSAlert()
        brandAlert(alert)
        alert.messageText = L10n.tr("Replyzen {0} ist verfügbar", update.manifest.version)
        alert.informativeText = update.manifest.localizedNotes
        alert.addButton(withTitle: L10n.tr("Installieren"))
        alert.addButton(withTitle: L10n.tr("Später"))

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        installUpdate(update)
    }

    private func installUpdate(_ update: UpdateManager.AvailableUpdate) {
        toolbarButton.setSuppressed(true)
        state.stage = .updating
        state.statusText = L10n.source("Version {0} wird heruntergeladen", update.manifest.version)
        panel.show()

        updateManager.install(update) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.state.statusText = L10n.source("Update ist vorbereitet – App startet gleich neu")
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
        alert.messageText = title == "Replyzen" ? ReplyZenBrand.displayName : ReplyZenBrand.displayName + " · " + L10n.render(title)
        alert.informativeText = L10n.render(message)
        alert.addButton(withTitle: L10n.tr("OK"))
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
        // When Reply is entered through the generic Replyzen window, keep the
        // historical default of Reply All. The explicit overlay buttons override it.
        if requestedMailMode == nil {
            state.replyScope = .all
        }
        if requestedMailMode == .reply {
            state.outputMode = .reply
            state.instruction = defaultReplyInstruction(for: state.replyLanguage)
        } else if requestedMailMode == .forward {
            state.outputMode = .forward
            state.instruction = ""
        } else if requestedMailMode == .calendar {
            state.outputMode = .calendar
            state.instruction = ""
        } else {
            state.outputMode = .newMail
            state.instruction = ""
        }
        state.instructionHTML = ""
        state.reminderEnabled = false
        state.reminderTime = "06:00"

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
        MailLanguageDetector.detect(in: mailText)
    }

    private func defaultReplyInstruction(for language: AppState.ReplyLanguage) -> String {
        language.defaultReplyInstruction
    }

    private func isDefaultReplyInstruction(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppState.ReplyLanguage.allCases.map(\.defaultReplyInstruction).contains(cleaned)
    }

    private func refreshMailContext() {
        guard !isLoadingMail else { return }

        activeSnapshot = nil
        state.mailText = ""

        guard outlook.isTrusted() else {
            state.outputMode = .newMail
            state.mailStatus = .unavailable(L10n.source("Keine Outlook-Mail verfügbar. Reply ist ausgeblendet."))
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
                    } else if self.requestedMailMode == .forward {
                        self.state.outputMode = .forward
                    } else if self.requestedMailMode == .calendar {
                        self.state.outputMode = .calendar
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
                            message = L10n.source("Outlook läuft gerade nicht. New Mail funktioniert trotzdem.")
                        case .noWindow, .noMailText:
                            message = L10n.source("Keine lesbare Outlook-Mail erkannt. New Mail funktioniert trotzdem.")
                        }
                    } else {
                        message = L10n.source("Mail-Kontext konnte nicht geladen werden. New Mail funktioniert trotzdem.")
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
        case .forward:
            forwardWithNote()
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
            state.mailStatus = .unavailable(L10n.source("Keine lesbare Outlook-Mail erkannt. Nutze New Mail oder versuche es erneut."))
            return
        }

        isRunningFlow = true
        toolbarButton.setSuppressed(true)
        state.stage = .generating
        state.statusText = L10n.source("OpenAI verarbeitet die Mail")

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
        state.statusText = L10n.source("OpenAI formuliert eine neue Mail")

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

    private func forwardWithNote() {
        guard let apiKey = keychain.loadAPIKey() else {
            state.stage = .apiKey
            return
        }

        let instruction = state.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        guard !state.mailText.isEmpty, activeSnapshot != nil else {
            state.mailStatus = .unavailable(L10n.source("Keine lesbare Outlook-Mail erkannt. Für Forward bitte eine Mail öffnen und erneut versuchen."))
            return
        }

        isRunningFlow = true
        toolbarButton.setSuppressed(true)
        state.stage = .generating
        state.statusText = L10n.source("OpenAI formuliert den Forward Text")

        openAI.generateForwardNote(
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
                    self.insertForwardDraft()
                case .failure(let error):
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func generateCalendarSuggestion() {
        guard let apiKey = keychain.loadAPIKey() else {
            state.stage = .apiKey
            panel.show()
            return
        }
        generateCalendarSuggestion(apiKey: apiKey)
    }

    private func generateCalendarSuggestion(apiKey: String) {
        guard !state.mailText.isEmpty else {
            state.mailStatus = .unavailable(L10n.source("Keine lesbare Outlook-Mail erkannt. Für einen Termin bitte eine Mail öffnen und erneut versuchen."))
            isRunningFlow = false
            toolbarButton.setSuppressed(false)
            return
        }

        isRunningFlow = true
        toolbarButton.setSuppressed(true)
        state.stage = .generating
        state.statusText = L10n.source("Replyzen erstellt den Terminvorschlag")

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
                        self.state.calendarWarning = L10n.source("Im Mailverlauf wurde kein eindeutiger Terminzeitpunkt erkannt. Bitte Datum und Uhrzeit prüfen.")
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
            state.mailStatus = .unavailable(L10n.source("Keine lesbare Outlook-Mail erkannt. Für eine Überweisung bitte die Rechnungsmail öffnen und erneut versuchen."))
            return
        }

        isRunningFlow = true
        toolbarButton.setSuppressed(true)
        state.stage = .generating
        state.statusText = L10n.source("Replyzen sucht den PDF-Anhang …")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let filenames = self.outlook.attachmentFilenames(from: snapshot)
            let mentionedPDF = filenames.first { $0.lowercased().hasSuffix(".pdf") }

            var directFiles = self.outlook.attachmentFileURLs(from: snapshot)
            var resolvedFiles = directFiles + self.attachmentExtractor.resolveFiles(filenames: filenames)
            var selectedPDFs = Array(resolvedFiles.filter { $0.pathExtension.lowercased() == "pdf" }.prefix(3))

            if selectedPDFs.isEmpty, let pdfName = mentionedPDF {
                DispatchQueue.main.sync {
                    self.state.statusText = L10n.source("PDF wird aus Outlook geladen …")
                    self.outlook.activateOutlook(pid: snapshot.pid)
                    _ = self.outlook.activateAttachment(named: pdfName, from: snapshot)
                }

                Thread.sleep(forTimeInterval: 1.6)
                let retrySnapshot = (try? self.outlook.captureSnapshot(includeAllWindows: true)) ?? snapshot
                directFiles = self.outlook.attachmentFileURLs(from: retrySnapshot)
                resolvedFiles = directFiles + self.attachmentExtractor.resolveFiles(filenames: filenames)
                selectedPDFs = Array(resolvedFiles.filter { $0.pathExtension.lowercased() == "pdf" }.prefix(3))

                // If Outlook still has not materialized the attachment, use its own
                // attachment context menu and Save As sheet automatically. This is
                // intentionally a last resort because direct AX file URLs are faster.
                if selectedPDFs.isEmpty {
                    var savedURL: URL?
                    DispatchQueue.main.sync {
                        self.state.statusText = L10n.source("PDF wird automatisch aus Outlook gespeichert …")
                        self.outlook.activateOutlook(pid: snapshot.pid)
                        savedURL = self.outlook.materializeAttachmentToTemporaryFile(named: pdfName, from: retrySnapshot)
                    }

                    if let savedURL {
                        selectedPDFs = [savedURL]
                    } else {
                        // Save/Download can complete without exposing a Save As sheet.
                        // Give Outlook a final moment, then search its caches/Downloads.
                        Thread.sleep(forTimeInterval: 1.0)
                        let finalSnapshot = (try? self.outlook.captureSnapshot(includeAllWindows: true)) ?? retrySnapshot
                        directFiles = self.outlook.attachmentFileURLs(from: finalSnapshot)
                        resolvedFiles = directFiles + self.attachmentExtractor.resolveFiles(filenames: filenames)
                        selectedPDFs = Array(resolvedFiles.filter { $0.pathExtension.lowercased() == "pdf" }.prefix(3))
                    }
                }
            }

            if selectedPDFs.isEmpty, let pdfName = mentionedPDF {
                var manuallySelectedPDF: URL?
                DispatchQueue.main.sync {
                    self.state.statusText = L10n.source("Outlook blockiert den PDF-Zugriff – bitte Rechnung auswählen …")
                    manuallySelectedPDF = self.choosePaymentPDFFallback(suggestedName: pdfName)
                }
                if let manuallySelectedPDF {
                    selectedPDFs = [manuallySelectedPDF]
                }
            }

            // A detected invoice PDF must be read as a real file. Never continue to
            // the blank payment form based only on mail text when Outlook blocks it.
            if selectedPDFs.isEmpty, mentionedPDF != nil {
                DispatchQueue.main.async {
                    self.isRunningFlow = false
                    self.toolbarButton.setSuppressed(false)
                    self.showSimpleAlert(
                        title: L10n.source("PDF nicht verfügbar"),
                        message: L10n.source("Outlook gibt den PDF-Anhang nicht frei. Bitte Payment erneut klicken und im Dateidialog die Rechnung auswählen.")
                    )
                }
                return
            }

            let replyzenTempDirectories = Set(selectedPDFs.compactMap { url -> URL? in
                guard url.path.contains("/Replyzen-Attachments/") else { return nil }
                return url.deletingLastPathComponent()
            })

            var fallbackText = ""
            var sourceStatus: String

            if !selectedPDFs.isEmpty {
                let wasAutoSaved = !replyzenTempDirectories.isEmpty
                sourceStatus = L10n.source(wasAutoSaved ? "PDF automatisch aus Outlook gespeichert und direkt mit OpenAI gelesen: {0}" : "PDF direkt mit OpenAI gelesen: {0}", selectedPDFs.map(\.lastPathComponent).joined(separator: ", "))
                DispatchQueue.main.async {
                    self.state.statusText = L10n.source("PDF wird direkt an OpenAI übergeben und gelesen …")
                }
            } else {
                let fallback = self.attachmentExtractor.extract(filenames: filenames)
                fallbackText = fallback.text

                let pdfMentioned = filenames.contains { $0.lowercased().hasSuffix(".pdf") }
                if !fallback.usedFiles.isEmpty {
                    sourceStatus = L10n.source("Kein direkt zugängliches PDF; lokal gelesen: {0}", fallback.usedFiles.joined(separator: ", "))
                } else if pdfMentioned {
                    sourceStatus = L10n.source("PDF-Anhang erkannt, aber Outlook konnte ihn weder lokal bereitstellen noch automatisch speichern.")
                } else {
                    sourceStatus = L10n.source("Kein PDF-Anhang erkannt. Extraktion aus dem Mailtext.")
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
                // OpenAI has completed reading/uploading at this point, so any
                // temporary Outlook Save As copies can be removed immediately.
                for directory in replyzenTempDirectories {
                    try? FileManager.default.removeItem(at: directory)
                }

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
                            self.state.paymentWarning = L10n.source("Kein PDF wurde direkt von OpenAI gelesen. Bitte Empfänger, IBAN und Betrag besonders sorgfältig prüfen.")
                        } else if confidence == "low" || missingCore {
                            self.state.paymentWarning = L10n.source("Die Extraktion ist nicht eindeutig. Bitte die PDF-Rechnung mit den Feldern unten vergleichen.")
                        } else {
                            self.state.paymentWarning = L10n.source("Bitte IBAN, Betrag und Verwendungszweck vor einer Überweisung immer mit der PDF-Rechnung vergleichen.")
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

    private func choosePaymentPDFFallback(suggestedName: String?) -> URL? {
        let picker = NSOpenPanel()
        picker.title = L10n.tr("Rechnung auswählen")
        picker.message = L10n.source("Outlook stellt den erkannten PDF-Anhang nicht als Datei bereit. Wähle die Rechnung einmal aus; Replyzen liest sie danach direkt mit OpenAI.")
        picker.prompt = L10n.tr("PDF verwenden")
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.allowedFileTypes = ["pdf"]

        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        if FileManager.default.fileExists(atPath: downloads.path) {
            picker.directoryURL = downloads
        }
        if let suggestedName, !suggestedName.isEmpty {
            picker.nameFieldStringValue = URL(fileURLWithPath: suggestedName).lastPathComponent
        }

        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK,
              let url = picker.url,
              url.pathExtension.lowercased() == "pdf" else { return nil }
        return url.standardizedFileURL
    }

    private func copyPaymentDetails() {
        let lines = [
            state.paymentRecipient.isEmpty ? nil : L10n.tr("Empfänger: {0}", state.paymentRecipient),
            state.paymentIBAN.isEmpty ? nil : "IBAN: \(state.paymentIBAN)",
            state.paymentBIC.isEmpty ? nil : "BIC: \(state.paymentBIC)",
            state.paymentAmount.isEmpty ? nil : L10n.tr("Betrag: {0} {1}", state.paymentAmount, state.paymentCurrency),
            state.paymentPurpose.isEmpty ? nil : L10n.tr("Verwendungszweck: {0}", state.paymentPurpose)
        ].compactMap { $0 }
        guard !lines.isEmpty else { return }
        copyToPasteboard(lines.joined(separator: "\n"))
        state.successMessage = L10n.tr("Überweisungsdaten wurden in die Zwischenablage kopiert. Bitte vor der Zahlung im Banking prüfen.")
        state.stage = .success
        panel.show()
    }

    private func createCalendarEvent() {
        let title = state.calendarTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        guard state.calendarEnd > state.calendarStart else {
            showError(L10n.source("Die Endzeit muss nach der Startzeit liegen."))
            return
        }

        guard !state.selectedCalendarID.isEmpty else {
            showError(L10n.source("Bitte zuerst einen Kalender auswählen."))
            return
        }
        UserDefaults.standard.set(state.selectedCalendarID, forKey: "Replyzen.SelectedMinuboCalendarID")

        isRunningFlow = true
        toolbarButton.setSuppressed(true)
        state.stage = .generating
        state.statusText = L10n.source("Termin wird direkt in Google Calendar angelegt")

        let selectedCalendarName = state.calendarOptions.first(where: { $0.id == state.selectedCalendarID })?.title ?? L10n.source("Kalender")
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
                    formatter.locale = L10n.locale
                    formatter.timeZone = CalendarManager.eventTimeZone
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .short
                    self.state.successMessage = L10n.source("„{0}“ wurde am {1} direkt in Google Calendar · „{2}“ angelegt.", title, L10n.DateValue(self.state.calendarStart, timeZone: CalendarManager.eventTimeZone), selectedCalendarName)
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
            state.googleOAuthStatus = L10n.source("Einmalig Google OAuth einrichten.")
            state.calendarListStatus = L10n.source("Google Calendar ist noch nicht verbunden.")
            return
        }

        state.googleNeedsOAuthCredentials = false
        guard let email = calendarManager.connectedEmail() else {
            state.googleOAuthStatus = L10n.source("Noch nicht mit Google verbunden.")
            state.calendarListStatus = L10n.source("Bitte mit lennard@minubo.com verbinden.")
            return
        }

        guard email.caseInsensitiveCompare(CalendarManager.targetEmail) == .orderedSame else {
            calendarManager.disconnect()
            state.googleConnectedEmail = ""
            state.googleOAuthStatus = L10n.source("Bitte mit lennard@minubo.com verbinden.")
            state.calendarListStatus = L10n.source("Falsches Google-Konto.")
            return
        }

        state.googleConnectedEmail = email
        state.googleOAuthStatus = L10n.source("Verbunden mit {0}", email)
        state.calendarListStatus = L10n.source("Google-Kalender werden geladen …")

        calendarManager.loadCalendarOptions { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let options):
                    self.state.calendarOptions = options
                    if options.isEmpty {
                        self.state.selectedCalendarID = ""
                        self.state.calendarListStatus = L10n.source("Keine beschreibbaren Google-Kalender gefunden.")
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
            state.googleOAuthStatus = L10n.source("Bitte Client-ID und Client Secret eintragen.")
            return
        }

        state.googleIsConnecting = true
        state.googleOAuthStatus = L10n.source("Google-Anmeldung wird im Browser geöffnet …")

        calendarManager.connect(clientID: clientID, clientSecret: clientSecret) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.state.googleIsConnecting = false
                switch result {
                case .success(let email):
                    self.state.googleConnectedEmail = email
                    self.state.googleNeedsOAuthCredentials = false
                    self.state.googleClientSecretDraft = ""
                    self.state.googleOAuthStatus = L10n.source("Verbunden mit {0}", email)
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
        state.googleOAuthStatus = L10n.source("Google Calendar wurde getrennt.")
        state.calendarListStatus = L10n.source("Bitte erneut mit lennard@minubo.com verbinden.")
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
        guard ["mon", "tues", "wed", "thurs", "fri", "sat", "sun"].contains(day), !time.isEmpty else { return nil }

        let compactTime = time.replacingOccurrences(of: ":", with: "")
        guard compactTime.count == 4, compactTime.allSatisfy({ $0.isNumber }) else { return nil }
        if compactTime == "0600" {
            return "\(day)@fut.io"
        }
        return "\(day)\(compactTime)@fut.io"
    }

    private func insertGeneratedText() {
        switch state.outputMode {
        case .reply:
            insertReply()
        case .newMail:
            insertNewMail()
        case .forward:
            insertForwardDraft()
        case .calendar, .payment:
            break
        }
    }

    private func insertReply() {
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
            _ = self.outlook.openReplyComposer(replyAll: replyAll, from: snapshot)

            // Legacy Outlook can report a failed AXPress even though it already
            // opened the reply window. Verify the actual UI state before using the
            // keyboard fallback so one action never creates duplicate reply windows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                if !self.outlook.hasOpenedReplyComposer(since: snapshot) {
                    if replyAll { self.keyboard.sendCommandShiftR() }
                    else { self.keyboard.sendCommandR() }
                }
                self.populateReplyDraft(reply: reply, html: self.state.replyHTML, attempt: 0)
            }
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

            // Classic Outlook can show a perfectly usable reply body without
            // exposing it as a focusable AX body element. The editable Subject field
            // is reliable; one Tab from Subject enters the body. Give normal body
            // detection two attempts first, then use this deterministic fallback.
            if attempt >= 2, self.outlook.focusComposeSubjectField() {
                self.keyboard.sendTab()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                    guard let self else { return }
                    self.keyboard.sendCommandUp()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                        guard let self else { return }
                        self.copyMailToPasteboard(plainText: reply, html: html)
                        self.keyboard.sendCommandV()
                        self.finishNewMailInsertion()
                    }
                }
                return
            }

            if attempt < 12 {
                self.populateReplyDraft(reply: reply, html: html, attempt: attempt + 1)
                return
            }

            self.copyMailToPasteboard(plainText: reply, html: html)
            self.isRunningFlow = false
            self.toolbarButton.setSuppressed(false)
            self.showError(L10n.source("Outlook hat den Antworteditor nicht geöffnet. Der Text wurde in die Zwischenablage kopiert."))
        }
    }

    private func insertForwardDraft() {
        guard let snapshot = activeSnapshot else {
            state.stage = .instruction
            state.mailStatus = .unavailable(L10n.source("Die ursprüngliche Outlook-Mail ist nicht mehr verfügbar. Bitte erneut laden."))
            return
        }

        let body = state.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let html = state.replyHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        guard outlook.isTrusted() else {
            copyMailToPasteboard(plainText: body, html: html)
            showError(L10n.source("Replyzen braucht Bedienungshilfen, um den Forward automatisch in Outlook vorzubereiten. Dein Text wurde in die Zwischenablage kopiert."))
            return
        }

        state.stage = .inserting
        state.statusText = L10n.source("Outlook Forward wird geöffnet; Thread und Anhänge bleiben erhalten")
        isRunningFlow = true
        toolbarButton.setSuppressed(true)
        panel.hide()
        outlook.activateOutlook(pid: snapshot.pid)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.keyboard.sendCommandJ()
            self.populateForwardDraft(body: body, html: html, attempt: 0)
        }
    }

    private func populateForwardDraft(body: String, html: String, attempt: Int) {
        let delay = attempt == 0 ? 0.95 : 0.28
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }

            if let reminder = self.reminderBCCAddress() {
                _ = self.outlook.setComposeBCCValue(reminder)
            }

            if self.outlook.focusComposeBodyField() {
                // Native Outlook Forward preserves the original message and its attachments.
                // Move to the very top and paste only the user's Replyzen note above it.
                self.keyboard.sendCommandUp()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    guard let self else { return }
                    let plain = body + "\n\n"
                    let rich = html.isEmpty ? "" : html + "<br><br>"
                    self.copyMailToPasteboard(plainText: plain, html: rich)
                    self.keyboard.sendCommandV()
                    self.finishNewMailInsertion()
                }
                return
            }

            // Legacy Outlook may not expose its HTML compose body through AX at all.
            // The subject field is exposed reliably, and one Tab from Subject enters
            // the native message body. Use that as a robust fallback.
            if self.outlook.focusComposeSubjectField() {
                self.keyboard.sendTab()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                    guard let self else { return }
                    self.keyboard.sendCommandUp()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                        guard let self else { return }
                        let plain = body + "\n\n"
                        let rich = html.isEmpty ? "" : html + "<br><br>"
                        self.copyMailToPasteboard(plainText: plain, html: rich)
                        self.keyboard.sendCommandV()
                        self.finishNewMailInsertion()
                    }
                }
                return
            }

            if attempt < 3 {
                self.populateForwardDraft(body: body, html: html, attempt: attempt + 1)
                return
            }

            self.copyMailToPasteboard(plainText: body, html: html)
            self.isRunningFlow = false
            self.showError(L10n.source("Der Forward wurde in Outlook geöffnet, aber Replyzen konnte den Text nicht automatisch über dem Thread einsetzen. Der Text liegt in der Zwischenablage."))
        }
    }

    private func insertNewMail() {
        let subject = state.newMailSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = state.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let html = state.replyHTML
        guard !body.isEmpty else { return }

        guard let pid = outlook.runningPID() else {
            copyMailToPasteboard(plainText: body, html: html)
            showError(L10n.source("Microsoft Outlook läuft nicht. Der Mailtext wurde in die Zwischenablage kopiert."))
            return
        }

        guard outlook.isTrusted() else {
            copyMailToPasteboard(plainText: body, html: html)
            outlook.requestTrustPrompt()
            showError(L10n.source("Replyzen braucht Bedienungshilfen, um automatisch eine neue Outlook-Mail zu befüllen. Der Mailtext wurde in die Zwischenablage kopiert."))
            return
        }

        state.stage = .inserting
        state.statusText = L10n.source("Neue Outlook-Mail wird geöffnet und befüllt")
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
                self.showError(L10n.source("Der Mailtext konnte nicht automatisch eingesetzt werden. Er liegt in der Zwischenablage."))
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
        MailTypography.write(plainText: plainText, html: html)
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
            showError(L10n.source("Der API-Key konnte nicht im macOS-Schlüsselbund gespeichert werden."))
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
