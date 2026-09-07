from pathlib import Path
import sys

root = Path(sys.argv[1])


def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f"{label} not found")
    return text.replace(old, new, 1)

# Calendar in the Outlook overlay should start immediately. Do not open the
# Replyzen instruction screen first. Read the active mail, detect language,
# ask OpenAI, then show only the editable calendar result window.
p = root / "app" / "AppDelegate.swift"
s = p.read_text()
s = must_replace(
    s,
    '        toolbarButton.calendarAction = { [weak self] in self?.openCalendarWorkspace() }\n',
    '        toolbarButton.calendarAction = { [weak self] in self?.createCalendarFromOverlay() }\n',
    "calendar overlay action",
)
s = must_replace(
    s,
    '''    private func openCalendarWorkspace() {\n        requestedMailMode = .calendar\n        replyAllForCurrentDraft = true\n        openWorkspace()\n    }\n''',
    '''    private func createCalendarFromOverlay() {\n        guard !isRunningFlow else { return }\n        guard let apiKey = keychain.loadAPIKey() else {\n            toolbarButton.setSuppressed(true)\n            state.apiKeyDraft = ""\n            state.stage = .apiKey\n            panel.show()\n            return\n        }\n        guard outlook.isTrusted() else {\n            outlook.requestTrustPrompt()\n            return\n        }\n\n        isRunningFlow = true\n        toolbarButton.setSuppressed(true)\n\n        DispatchQueue.global(qos: .userInitiated).async { [weak self] in\n            guard let self else { return }\n\n            do {\n                var snapshot = try self.outlook.captureSnapshot(includeAllWindows: false)\n                var mail: String\n                do {\n                    mail = try self.outlook.readMail(from: snapshot)\n                } catch OutlookAccessibility.OutlookError.noMailText {\n                    snapshot = try self.outlook.captureSnapshot(includeAllWindows: true)\n                    mail = try self.outlook.readMail(from: snapshot)\n                }\n\n                DispatchQueue.main.async {\n                    self.activeSnapshot = snapshot\n                    self.state.mailText = mail\n                    self.state.mailStatus = .available\n                    self.state.outputMode = .calendar\n                    if let language = self.detectReplyLanguage(in: mail) {\n                        self.state.replyLanguage = language\n                    }\n                    // Keep the panel hidden while OpenAI works. The existing\n                    // calendar generator opens only the result window on success.\n                    self.generateCalendarSuggestion(apiKey: apiKey)\n                }\n            } catch {\n                DispatchQueue.main.async {\n                    self.isRunningFlow = false\n                    self.toolbarButton.setSuppressed(false)\n                    self.showSimpleAlert(\n                        title: "Termin nicht erstellt",\n                        message: "Die geöffnete Outlook-Mail konnte nicht gelesen werden."\n                    )\n                }\n            }\n        }\n    }\n''',
    "direct calendar method",
)

old_calendar = '''    private func generateCalendarSuggestion() {\n        guard let apiKey = keychain.loadAPIKey() else {\n            state.stage = .apiKey\n            return\n        }\n\n        guard !state.mailText.isEmpty else {\n            state.mailStatus = .unavailable("Keine lesbare Outlook-Mail erkannt. Für einen Termin bitte eine Mail öffnen und erneut versuchen.")\n            return\n        }\n\n        isRunningFlow = true\n        toolbarButton.setSuppressed(true)\n        state.stage = .generating\n        state.statusText = "Replyzen erstellt den Terminvorschlag"\n\n        openAI.createCalendarSuggestion(\n            apiKey: apiKey,\n'''
new_calendar = '''    private func generateCalendarSuggestion() {\n        guard let apiKey = keychain.loadAPIKey() else {\n            state.stage = .apiKey\n            panel.show()\n            return\n        }\n        generateCalendarSuggestion(apiKey: apiKey)\n    }\n\n    private func generateCalendarSuggestion(apiKey: String) {\n        guard !state.mailText.isEmpty else {\n            state.mailStatus = .unavailable("Keine lesbare Outlook-Mail erkannt. Für einen Termin bitte eine Mail öffnen und erneut versuchen.")\n            isRunningFlow = false\n            toolbarButton.setSuppressed(false)\n            return\n        }\n\n        isRunningFlow = true\n        toolbarButton.setSuppressed(true)\n        state.stage = .generating\n        state.statusText = "Replyzen erstellt den Terminvorschlag"\n\n        openAI.createCalendarSuggestion(\n            apiKey: apiKey,\n'''
s = must_replace(s, old_calendar, new_calendar, "calendar generator overload")
p.write_text(s)

# Cache the OpenAI key in memory after the first successful Keychain read in a
# running Replyzen process. This prevents redundant Keychain reads within one
# launch. It intentionally does not weaken Keychain access controls.
p = root / "app" / "KeychainStore.swift"
s = p.read_text()
s = must_replace(
    s,
    '    private let account = "openai-api-key"\n',
    '    private let account = "openai-api-key"\n    private var cachedAPIKey: String?\n',
    "key cache property",
)
s = must_replace(
    s,
    '''    func loadAPIKey() -> String? {\n        if let key = load(from: service) {\n            return key\n        }\n\n        // One-time migration from the previous Lennard Outlook AI app.\n        if let legacyKey = load(from: legacyService) {\n            _ = saveAPIKey(legacyKey)\n            return legacyKey\n        }\n\n        return nil\n    }\n''',
    '''    func loadAPIKey() -> String? {\n        if let cachedAPIKey { return cachedAPIKey }\n\n        if let key = load(from: service) {\n            cachedAPIKey = key\n            return key\n        }\n\n        // One-time migration from the previous Lennard Outlook AI app.\n        if let legacyKey = load(from: legacyService) {\n            _ = saveAPIKey(legacyKey)\n            cachedAPIKey = legacyKey\n            return legacyKey\n        }\n\n        return nil\n    }\n''',
    "key cache load",
)
s = must_replace(
    s,
    '''        if updateStatus == errSecSuccess {\n            return true\n        }\n\n        var add = base\n        add[kSecValueData as String] = data\n        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess\n''',
    '''        if updateStatus == errSecSuccess {\n            cachedAPIKey = key\n            return true\n        }\n\n        var add = base\n        add[kSecValueData as String] = data\n        let saved = SecItemAdd(add as CFDictionary, nil) == errSecSuccess\n        if saved { cachedAPIKey = key }\n        return saved\n''',
    "key cache save",
)
p.write_text(s)

# Version and release metadata.
p = root / "app" / "Info.plist"
s = p.read_text()
s = s.replace('<string>1.35.0</string>', '<string>1.36.0</string>', 1)
s = s.replace('<string>36</string>', '<string>37</string>', 1)
p.write_text(s)

p = root / "Build-CI.sh"
s = p.read_text()
s = s.replace('Replyzen-update-1.35.zip', 'Replyzen-update-1.36.zip')
s = s.replace(
    'Replyzen 1.35: Das Outlook Overlay sitzt wieder ein kleines Stück höher, ohne den Suchschlitz zu überdecken, und hebt sich mit einem sehr dezenten eigenen Hintergrund vom Standardgrau ab. Enthält weiterhin die einheitliche Mail Form für New, Reply und Forward sowie Termin nur im Outlook Overlay hinter Cancel.',
    'Replyzen 1.36: Termin startet jetzt direkt aus dem Outlook Overlay. Replyzen liest die aktuelle Mail, erkennt die Sprache und fragt OpenAI sofort; erst das fertige editierbare Termin Ergebnisfenster wird angezeigt. OpenAI Keychain Zugriffe werden innerhalb eines App Starts gecacht.'
)
p.write_text(s)
