from pathlib import Path
import sys

root = Path(sys.argv[1])

# 1) OpenAI file uploads: always send PDF filenames with a lowercase .pdf extension.
# The Responses API validates context-stuffing file extensions case-sensitively, so
# an otherwise valid invoice named *.PDF could upload successfully and then fail at
# input_file processing with "got .PDF".
p = root / "app" / "OpenAIClient.swift"
s = p.read_text()
old = '''        let boundary = "Replyzen-\\(UUID().uuidString)"\n        let safeFilename = url.lastPathComponent.replacingOccurrences(of: "\\\\\"", with: "_")\n        var body = Data()\n'''
new = '''        let boundary = "Replyzen-\\(UUID().uuidString)"\n        let originalFilename = url.lastPathComponent.replacingOccurrences(of: "\\\\\"", with: "_")\n        let safeFilename: String\n        if url.pathExtension.lowercased() == "pdf" {\n            let stem = URL(fileURLWithPath: originalFilename).deletingPathExtension().lastPathComponent\n            safeFilename = (stem.isEmpty ? "invoice" : stem) + ".pdf"\n        } else {\n            safeFilename = originalFilename\n        }\n        var body = Data()\n'''
if old not in s:
    raise SystemExit("OpenAI upload filename block not found")
s = s.replace(old, new, 1)
p.write_text(s)

# 2) Legacy Outlook works more reliably with attachments when the selected message
# is opened in its own message window rather than only displayed in the reading pane.
# Detect the main Outlook window (mailbox/message list outside the web area), press
# Return to open the selected message, then recapture the Outlook accessibility tree.
p = root / "app" / "OutlookAccessibility.swift"
s = p.read_text()
marker = '''    func activateAttachment(named filename: String, from snapshot: Snapshot) -> Bool {\n'''
insert = '''    func openSelectedMessageWindowIfNeeded(from snapshot: Snapshot) -> Snapshot {\n        guard let focusedWindow = snapshot.windows.first,\n              looksLikeMainOutlookWindow(focusedWindow) else {\n            return snapshot\n        }\n\n        activateOutlook(pid: snapshot.pid)\n        postKey(code: 36) // Return opens the currently selected message in Legacy Outlook.\n        Thread.sleep(forTimeInterval: 0.85)\n\n        return (try? captureSnapshot(includeAllWindows: true)) ?? snapshot\n    }\n\n    private func looksLikeMainOutlookWindow(_ window: AXUIElement) -> Bool {\n        // Main Outlook contains the folder/message list as a large outline/table.\n        // Ignore tables inside AXWebArea so HTML tables in an opened email do not\n        // make a standalone message window look like the main mailbox window.\n        var stack: [(AXUIElement, Int)] = [(window, 0)]\n        var visited = 0\n\n        while let (element, depth) = stack.popLast(), visited < 10_000 {\n            visited += 1\n            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""\n\n            if role == "AXWebArea" {\n                continue\n            }\n\n            if depth <= 9, role == "AXOutline" || role == "AXTable" {\n                if let size = sizeAttribute(kAXSizeAttribute as CFString, from: element),\n                   size.width > 180, size.height > 180 {\n                    return true\n                }\n            }\n\n            if depth < 10 {\n                for child in children(of: element).reversed() {\n                    stack.append((child, depth + 1))\n                }\n            }\n        }\n        return false\n    }\n\n    func activateAttachment(named filename: String, from snapshot: Snapshot) -> Bool {\n'''
if marker not in s:
    raise SystemExit("activateAttachment marker not found")
s = s.replace(marker, insert, 1)
p.write_text(s)

# 3) Payment overlay: before attachment discovery, open a selected reading-pane mail
# in its own Outlook window when needed, then use that recaptured snapshot/mail text.
p = root / "app" / "AppDelegate.swift"
s = p.read_text()
old = '''                DispatchQueue.main.async {\n                    self.activeSnapshot = snapshot\n                    self.state.mailText = mail\n                    self.state.mailStatus = .available\n                    self.state.outputMode = .payment\n                    // Do not show the normal Replyzen form. The existing extractor\n                    // opens only the editable payment result window when finished.\n                    self.generatePaymentSuggestion()\n                }\n'''
new = '''                var paymentSnapshot = snapshot\n                var paymentMail = mail\n\n                // In Legacy Outlook an attachment is often only fully exposed after\n                // the selected message is opened in its own window. Do that\n                // automatically when we are still in the mailbox/reading-pane view.\n                DispatchQueue.main.sync {\n                    paymentSnapshot = self.outlook.openSelectedMessageWindowIfNeeded(from: snapshot)\n                }\n                if let refreshedMail = try? self.outlook.readMail(from: paymentSnapshot),\n                   !refreshedMail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {\n                    paymentMail = refreshedMail\n                }\n\n                DispatchQueue.main.async {\n                    self.activeSnapshot = paymentSnapshot\n                    self.state.mailText = paymentMail\n                    self.state.mailStatus = .available\n                    self.state.outputMode = .payment\n                    // Do not show the normal Replyzen form. The existing extractor\n                    // opens only the editable payment result window when finished.\n                    self.generatePaymentSuggestion()\n                }\n'''
if old not in s:
    raise SystemExit("createPaymentFromOverlay block not found")
s = s.replace(old, new, 1)
p.write_text(s)

# 4) Version metadata.
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
    'Replyzen 1.42: Payment öffnet eine im Outlook Lesebereich ausgewählte Mail bei Bedarf automatisch in einem eigenen Nachrichtenfenster, bevor auf den PDF-Anhang zugegriffen wird. Zusätzlich werden PDF-Dateinamen beim OpenAI Upload immer mit kleingeschriebener .pdf Endung übertragen, damit Dateien mit .PDF nicht mehr an der Dateityp-Prüfung scheitern.'
)
p.write_text(s)
