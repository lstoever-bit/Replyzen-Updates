from pathlib import Path
import sys

root = Path(sys.argv[1])

# 1) Make Outlook attachment context-menu access more robust by synthesizing
# a real right click when AXShowMenu is not exposed by Legacy Outlook.
p = root / "app" / "OutlookAccessibility.swift"
s = p.read_text()
old = r'''    private func showAttachmentMenu(for element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<7 {
            guard let candidate = current else { break }
            if AXUIElementPerformAction(candidate, "AXShowMenu" as CFString) == .success {
                return true
            }
            current = axElementAttribute(kAXParentAttribute as CFString, from: candidate)
        }
        return false
    }
'''
new = r'''    private func showAttachmentMenu(for element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        var rightClickTarget: AXUIElement = element
        var bestArea: CGFloat = 0

        for _ in 0..<8 {
            guard let candidate = current else { break }
            if AXUIElementPerformAction(candidate, "AXShowMenu" as CFString) == .success {
                return true
            }

            if let size = sizeAttribute(kAXSizeAttribute as CFString, from: candidate) {
                let area = size.width * size.height
                if size.width >= 28, size.height >= 18, area > bestArea {
                    bestArea = area
                    rightClickTarget = candidate
                }
            }
            current = axElementAttribute(kAXParentAttribute as CFString, from: candidate)
        }

        // Legacy Outlook frequently exposes no AXShowMenu action at all even though
        // a normal right click on the attachment card opens the menu. Reproduce that
        // native interaction at the attachment card center as a second route.
        guard let position = pointAttribute(kAXPositionAttribute as CFString, from: rightClickTarget),
              let size = sizeAttribute(kAXSizeAttribute as CFString, from: rightClickTarget),
              size.width > 0, size.height > 0,
              let source = CGEventSource(stateID: .hidSystemState) else { return false }

        let point = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        guard let down = CGEvent(
            mouseEventSource: source,
            mouseType: .rightMouseDown,
            mouseCursorPosition: point,
            mouseButton: .right
        ), let up = CGEvent(
            mouseEventSource: source,
            mouseType: .rightMouseUp,
            mouseCursorPosition: point,
            mouseButton: .right
        ) else { return false }

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
'''
if old not in s:
    raise SystemExit("showAttachmentMenu block not found")
s = s.replace(old, new, 1)

# Give Outlook's context menu a little longer to appear after the synthetic click.
s = s.replace('        Thread.sleep(forTimeInterval: 0.22)\n        guard let selectedTitle = pressBestSaveAttachmentMenuItem',
              '        Thread.sleep(forTimeInterval: 0.48)\n        guard let selectedTitle = pressBestSaveAttachmentMenuItem', 1)
p.write_text(s)

# 2) If Outlook still refuses to materialize the PDF, do not show an empty payment
# result. Open a focused PDF picker as the final fallback, then continue with the
# exact same OpenAI file flow. If the user cancels, stop with a clear alert.
p = root / "app" / "AppDelegate.swift"
s = p.read_text()
marker = r'''            let replyzenTempDirectories = Set(selectedPDFs.compactMap { url -> URL? in
'''
insert = r'''            if selectedPDFs.isEmpty, let pdfName = mentionedPDF {
                var manuallySelectedPDF: URL?
                DispatchQueue.main.sync {
                    self.state.statusText = "Outlook blockiert den PDF-Zugriff – bitte Rechnung auswählen …"
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
                        title: "PDF nicht verfügbar",
                        message: "Outlook gibt den PDF-Anhang nicht frei. Bitte Payment erneut klicken und im Dateidialog die Rechnung auswählen."
                    )
                }
                return
            }

            let replyzenTempDirectories = Set(selectedPDFs.compactMap { url -> URL? in
'''
if marker not in s:
    raise SystemExit("payment temp directory marker not found")
s = s.replace(marker, insert, 1)

helper_marker = r'''    private func copyPaymentDetails() {
'''
helper = r'''    private func choosePaymentPDFFallback(suggestedName: String?) -> URL? {
        let picker = NSOpenPanel()
        picker.title = "Rechnung auswählen"
        picker.message = "Outlook stellt den erkannten PDF-Anhang nicht als Datei bereit. Wähle die Rechnung einmal aus; Replyzen liest sie danach direkt mit OpenAI."
        picker.prompt = "PDF verwenden"
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
'''
if helper_marker not in s:
    raise SystemExit("copyPaymentDetails marker not found")
s = s.replace(helper_marker, helper, 1)
p.write_text(s)

# 3) Version metadata.
p = root / "app" / "Info.plist"
s = p.read_text()
s = s.replace('<string>1.40.0</string>', '<string>1.41.0</string>', 1)
s = s.replace('<string>41</string>', '<string>42</string>', 1)
p.write_text(s)

p = root / "Build-CI.sh"
s = p.read_text()
s = s.replace('Replyzen-update-1.40.zip', 'Replyzen-update-1.41.zip')
s = s.replace(
    'Replyzen 1.40: Payment materialisiert PDF-Anhänge deutlich robuster. Replyzen versucht zuerst direkte Outlook-Datei-URLs und Cache-Dateien, öffnet den Anhang über die vollständige Accessibility-Elternkette und nutzt als letzten automatischen Fallback Outlooks eigenes Save-As-Menü in einen temporären Replyzen-Ordner. Die temporäre PDF wird nach der OpenAI-Auswertung gelöscht.',
    'Replyzen 1.41: Payment versucht bei Legacy Outlook zusätzlich einen echten Rechtsklick auf die Anhangskarte, wenn AXShowMenu fehlt. Falls Outlook den PDF-Anhang trotzdem technisch blockiert, öffnet Replyzen als letzten Fallback direkt einen PDF-Dateidialog statt eine leere Überweisungsmaske anzuzeigen. Die ausgewählte PDF wird anschließend wie gewohnt direkt mit OpenAI gelesen.'
)
p.write_text(s)
