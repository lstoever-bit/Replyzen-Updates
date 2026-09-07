from pathlib import Path
import sys

root = Path(sys.argv[1])

# 1) OpenAI file uploads: always send PDF filenames with a lowercase .pdf extension.
# The Responses API file validation rejects an otherwise valid invoice if its
# uploaded filename ends in uppercase .PDF.
p = root / "app" / "OpenAIClient.swift"
s = p.read_text()
lines = s.splitlines()
for i, line in enumerate(lines):
    if "let safeFilename = url.lastPathComponent.replacingOccurrences" in line:
        indent = line[:len(line) - len(line.lstrip())]
        lines[i:i+1] = [
            indent + 'let originalFilename = url.lastPathComponent.replacingOccurrences(of: "\\\"", with: "_")',
            indent + 'let safeFilename: String',
            indent + 'if url.pathExtension.lowercased() == "pdf" {',
            indent + '    let stem = URL(fileURLWithPath: originalFilename).deletingPathExtension().lastPathComponent',
            indent + '    safeFilename = (stem.isEmpty ? "invoice" : stem) + ".pdf"',
            indent + '} else {',
            indent + '    safeFilename = originalFilename',
            indent + '}',
        ]
        break
else:
    raise SystemExit("OpenAI safeFilename line not found")
s = "\n".join(lines) + "\n"
p.write_text(s)

# 2) Legacy Outlook: if Payment is triggered while a message is only shown in the
# reading pane, open the selected message in its own window first. Attachments are
# exposed much more reliably there. Already-open message windows are left alone.
p = root / "app" / "OutlookAccessibility.swift"
s = p.read_text()
marker = '''    func activateAttachment(named filename: String, from snapshot: Snapshot) -> Bool {\n'''
insert = '''    func openSelectedMessageWindowIfNeeded(from snapshot: Snapshot) -> Snapshot {\n        guard let focusedWindow = snapshot.windows.first,\n              looksLikeMainOutlookWindow(focusedWindow) else {\n            return snapshot\n        }\n\n        activateOutlook(pid: snapshot.pid)\n        focusSelectedMessageRow(in: focusedWindow)\n        postKey(code: 36) // Return opens the selected message in Legacy Outlook.\n        Thread.sleep(forTimeInterval: 0.95)\n\n        return (try? captureSnapshot(includeAllWindows: true)) ?? snapshot\n    }\n\n    private func looksLikeMainOutlookWindow(_ window: AXUIElement) -> Bool {\n        // The mailbox window contains a large outline/table outside the message\n        // web area. A standalone message window normally does not.\n        var stack: [(AXUIElement, Int)] = [(window, 0)]\n        var visited = 0\n\n        while let (element, depth) = stack.popLast(), visited < 10_000 {\n            visited += 1\n            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""\n\n            if role == "AXWebArea" { continue }\n\n            if depth <= 9 && (role == "AXOutline" || role == "AXTable") {\n                if let size = sizeAttribute(kAXSizeAttribute as CFString, from: element),\n                   size.width > 180, size.height > 180 {\n                    return true\n                }\n            }\n\n            if depth < 10 {\n                for child in children(of: element).reversed() {\n                    stack.append((child, depth + 1))\n                }\n            }\n        }\n        return false\n    }\n\n    private func focusSelectedMessageRow(in window: AXUIElement) {\n        var stack: [AXUIElement] = [window]\n        var visited = 0\n        while let element = stack.popLast(), visited < 12_000 {\n            visited += 1\n            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""\n            if role == "AXRow", boolAttribute(kAXSelectedAttribute as CFString, from: element) == true {\n                _ = focus(element)\n                return\n            }\n            if role != "AXWebArea" {\n                for child in children(of: element).reversed() { stack.append(child) }\n            }\n        }\n    }\n\n    func activateAttachment(named filename: String, from snapshot: Snapshot) -> Bool {\n'''
if marker not in s:
    raise SystemExit("activateAttachment marker not found")
s = s.replace(marker, insert, 1)

# Add a small bool AX helper beside the existing attribute helpers.
helper_marker = '''    private func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {\n'''
helper = '''    private func boolAttribute(_ attribute: CFString, from element: AXUIElement) -> Bool? {\n        var value: CFTypeRef?\n        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }\n        if let number = value as? NSNumber { return number.boolValue }\n        return nil\n    }\n\n    private func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {\n'''
if helper_marker not in s:
    raise SystemExit("stringAttribute marker not found")
s = s.replace(helper_marker, helper, 1)
p.write_text(s)

# 3) Payment overlay: before attachment discovery, open a selected reading-pane mail
# in its own Outlook window when needed, then use the refreshed snapshot and mail.
p = root / "app" / "AppDelegate.swift"
s = p.read_text()
old = '''                DispatchQueue.main.async {\n                    self.activeSnapshot = snapshot\n                    self.state.mailText = mail\n                    self.state.mailStatus = .available\n                    self.state.outputMode = .payment\n                    // Do not show the normal Replyzen form. The existing extractor\n                    // opens only the editable payment result window when finished.\n                    self.generatePaymentSuggestion()\n                }\n'''
new = '''                var paymentSnapshot = snapshot\n                var paymentMail = mail\n\n                // Legacy Outlook exposes attachment files more reliably once the\n                // selected mail is opened in its own message window.\n                DispatchQueue.main.sync {\n                    paymentSnapshot = self.outlook.openSelectedMessageWindowIfNeeded(from: snapshot)\n                }\n                if let refreshedMail = try? self.outlook.readMail(from: paymentSnapshot),\n                   !refreshedMail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {\n                    paymentMail = refreshedMail\n                }\n\n                DispatchQueue.main.async {\n                    self.activeSnapshot = paymentSnapshot\n                    self.state.mailText = paymentMail\n                    self.state.mailStatus = .available\n                    self.state.outputMode = .payment\n                    // Do not show the normal Replyzen form. The existing extractor\n                    // opens only the editable payment result window when finished.\n                    self.generatePaymentSuggestion()\n                }\n'''
if old not in s:
    raise SystemExit("createPaymentFromOverlay block not found")
s = s.replace(old, new, 1)

# 4) Replyzen follows Outlook's visible lifecycle. The login item remains a tiny,
# invisible watcher so Replyzen can appear again when Outlook is launched later.
# User-visible Replyzen UI/menu/overlay exists only while Outlook is running.
property_marker = '''    private var replyAllForCurrentDraft = true\n'''
property_insert = '''    private var replyAllForCurrentDraft = true\n    private var outlookLaunchObserver: NSObjectProtocol?\n    private var outlookTerminateObserver: NSObjectProtocol?\n    private var outlookSessionActive = false\n'''
if property_marker not in s:
    raise SystemExit("AppDelegate property marker not found")
s = s.replace(property_marker, property_insert, 1)

old_launch = '''        migrateExistingAPIKeyIfPossible()\n        configureStateActions()\n        panel.onClose = { [weak self] in self?.closePanel() }\n        configureStatusItem()\n        configureHotKey()\n        configureToolbarButton()\n        configureUpdates()\n\n        _ = loginItem.enableAtLoginIfPossible()\n\n        if keychain.loadAPIKey() == nil {\n            state.stage = .apiKey\n            panel.show()\n        } else {\n            state.startupJoke = startupJoke()\n            state.stage = .startup\n            panel.show(activate: true)\n        }\n\n        if !outlook.isTrusted() {\n            outlook.requestTrustPrompt()\n        }\n'''
new_launch = '''        migrateExistingAPIKeyIfPossible()\n        configureStateActions()\n        panel.onClose = { [weak self] in self?.closePanel() }\n        configureHotKey()\n        configureToolbarButton()\n        configureUpdates()\n        configureOutlookLifecycle()\n\n        // The login item is intentionally kept as a silent watcher. Without a tiny\n        // background process macOS could not relaunch Replyzen exactly when Outlook\n        // opens. No Replyzen UI is shown while Outlook is closed.\n        _ = loginItem.enableAtLoginIfPossible()\n\n        if isOutlookRunning {\n            activateForOutlook()\n        } else {\n            deactivateForOutlook()\n        }\n'''
if old_launch not in s:
    raise SystemExit("applicationDidFinishLaunching block not found")
s = s.replace(old_launch, new_launch, 1)

# Status item becomes idempotent because it is created/removed with Outlook.
status_marker = '''    private func configureStatusItem() {\n        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)\n'''
status_new = '''    private func configureStatusItem() {\n        guard statusItem == nil else { return }\n        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)\n'''
if status_marker not in s:
    raise SystemExit("configureStatusItem marker not found")
s = s.replace(status_marker, status_new, 1)

# Hotkey should do nothing while Outlook is closed.
hotkey_old = '''    private func configureHotKey() {\n        hotKey.action = { [weak self] in self?.openWorkspace() }\n        hotKey.start()\n    }\n'''
hotkey_new = '''    private func configureHotKey() {\n        hotKey.action = { [weak self] in\n            guard let self, self.isOutlookRunning else { return }\n            self.openWorkspace()\n        }\n        hotKey.start()\n    }\n'''
if hotkey_old not in s:
    raise SystemExit("configureHotKey block not found")
s = s.replace(hotkey_old, hotkey_new, 1)

# Configure overlay actions once; start/stop the overlay timer with Outlook.
toolbar_old = '''        toolbarButton.paymentAction = { [weak self] in self?.createPaymentFromOverlay() }\n        toolbarButton.start()\n    }\n'''
toolbar_new = '''        toolbarButton.paymentAction = { [weak self] in self?.createPaymentFromOverlay() }\n    }\n'''
if toolbar_old not in s:
    raise SystemExit("configureToolbarButton tail not found")
s = s.replace(toolbar_old, toolbar_new, 1)

# Insert Outlook lifecycle helpers before New Mail workspace handling.
lifecycle_marker = '''    private func openNewMailWorkspace() {\n'''
lifecycle_helpers = '''    private var isOutlookRunning: Bool {\n        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.microsoft.Outlook" }\n    }\n\n    private func configureOutlookLifecycle() {\n        let center = NSWorkspace.shared.notificationCenter\n\n        outlookLaunchObserver = center.addObserver(\n            forName: NSWorkspace.didLaunchApplicationNotification,\n            object: nil,\n            queue: .main\n        ) { [weak self] notification in\n            guard let self,\n                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,\n                  app.bundleIdentifier == "com.microsoft.Outlook" else { return }\n            self.activateForOutlook()\n        }\n\n        outlookTerminateObserver = center.addObserver(\n            forName: NSWorkspace.didTerminateApplicationNotification,\n            object: nil,\n            queue: .main\n        ) { [weak self] notification in\n            guard let self,\n                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,\n                  app.bundleIdentifier == "com.microsoft.Outlook" else { return }\n            self.deactivateForOutlook()\n        }\n    }\n\n    private func activateForOutlook() {\n        guard !outlookSessionActive else { return }\n        outlookSessionActive = true\n        configureStatusItem()\n        toolbarButton.setSuppressed(false)\n        toolbarButton.start()\n\n        if !outlook.isTrusted() {\n            outlook.requestTrustPrompt()\n        }\n\n        // Do not pop up the old startup window every time Outlook launches. The\n        // menu-bar icon and Outlook overlay are the visible Replyzen surface. Only\n        // first-time API-key setup needs a panel automatically.\n        if keychain.loadAPIKey() == nil {\n            state.stage = .apiKey\n            panel.show()\n        } else {\n            state.stage = .idle\n            panel.hide()\n        }\n    }\n\n    private func deactivateForOutlook() {\n        outlookSessionActive = false\n        isRunningFlow = false\n        isLoadingMail = false\n        activeSnapshot = nil\n        panel.hide()\n        toolbarButton.stop()\n\n        if let item = statusItem {\n            NSStatusBar.system.removeStatusItem(item)\n            statusItem = nil\n        }\n    }\n\n    private func openNewMailWorkspace() {\n'''
if lifecycle_marker not in s:
    raise SystemExit("openNewMailWorkspace marker not found")
s = s.replace(lifecycle_marker, lifecycle_helpers, 1)

# Remove workspace observers if the background watcher itself is explicitly quit.
terminate_marker = '''    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool {\n'''
terminate_insert = '''    func applicationWillTerminate(_ notification: Notification) {\n        let center = NSWorkspace.shared.notificationCenter\n        if let outlookLaunchObserver { center.removeObserver(outlookLaunchObserver) }\n        if let outlookTerminateObserver { center.removeObserver(outlookTerminateObserver) }\n        toolbarButton.stop()\n    }\n\n    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool {\n'''
if terminate_marker not in s:
    raise SystemExit("secure state marker not found")
s = s.replace(terminate_marker, terminate_insert, 1)
p.write_text(s)

# 5) Version metadata.
p = root / "app" / "Info.plist"
s = p.read_text()
s = s.replace('<string>1.41.0</string>', '<string>1.42.0</string>', 1)
s = s.replace('<string>42</string>', '<string>43</string>', 1)
p.write_text(s)

p = root / "Build-CI.sh"
s = p.read_text()
s = s.replace('Replyzen-update-1.41.zip', 'Replyzen-update-1.42.zip')
s = s.replace(
    'Replyzen 1.41: Payment versucht bei Legacy Outlook zusätzlich einen echten Rechtsklick auf die Anhangskarte, wenn AXShowMenu fehlt. Falls Outlook den PDF-Anhang trotzdem technisch blockiert, öffnet Replyzen als letzten Fallback direkt einen PDF-Dateidialog statt eine leere Überweisungsmaske anzuzeigen. Die ausgewählte PDF wird anschließend wie gewohnt direkt mit OpenAI gelesen.',
    'Replyzen 1.42: Payment öffnet eine im Outlook Lesebereich ausgewählte Mail bei Bedarf automatisch in einem eigenen Nachrichtenfenster, bevor auf den PDF-Anhang zugegriffen wird. PDF-Dateinamen werden beim OpenAI Upload immer mit kleingeschriebener .pdf Endung übertragen, damit .PDF Dateien nicht mehr an der Dateityp-Prüfung scheitern. Replyzens sichtbare Oberfläche und Menüleiste erscheinen automatisch mit Outlook und verschwinden wieder, wenn Outlook geschlossen wird.'
)
p.write_text(s)
