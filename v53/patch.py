from pathlib import Path
import sys

root = Path(sys.argv[1])

# 1) Outlook attachment handling: walk the full attachment ancestor chain and,
# if Outlook still does not expose a local PDF, use the attachment context menu
# to Save As into a private Replyzen temp folder.
p = root / "app" / "OutlookAccessibility.swift"
s = p.read_text()
old = r'''    func activateAttachment(named filename: String, from snapshot: Snapshot) -> Bool {
        let needle = filename.lowercased()
        guard !needle.isEmpty else { return false }
        let attributes: [CFString] = [
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString,
            kAXValueAttribute as CFString,
            "AXFilename" as CFString
        ]

        for window in snapshot.windows {
            var stack: [AXUIElement] = [window]
            var visited = 0
            while let element = stack.popLast(), visited < 20_000 {
                visited += 1
                let meta = attributes.compactMap { stringLikeAttribute($0, from: element) }
                    .joined(separator: " ")
                    .lowercased()
                if meta.contains(needle) {
                    if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                        return true
                    }
                    if let parent = axElementAttribute(kAXParentAttribute as CFString, from: element),
                       AXUIElementPerformAction(parent, kAXPressAction as CFString) == .success {
                        return true
                    }
                }
                for child in children(of: element).reversed() { stack.append(child) }
            }
        }
        return false
    }
'''
new = r'''    func activateAttachment(named filename: String, from snapshot: Snapshot) -> Bool {
        guard let element = attachmentElement(named: filename, from: snapshot) else { return false }

        // Outlook often exposes the visible filename as a static child while the
        // clickable attachment card lives several parents above it. Walk the chain
        // instead of trying only one parent.
        var current: AXUIElement? = element
        for _ in 0..<7 {
            guard let candidate = current else { break }
            if AXUIElementPerformAction(candidate, kAXPressAction as CFString) == .success {
                return true
            }
            current = axElementAttribute(kAXParentAttribute as CFString, from: candidate)
        }
        return false
    }

    /// Last-resort Outlook attachment materialization for PDFs that are visible in
    /// the UI but not yet present on disk. Uses the attachment context menu and the
    /// native Save As sheet, saving into a unique Replyzen temp directory.
    /// Must be called on the main thread because it drives Outlook UI events.
    func materializeAttachmentToTemporaryFile(named filename: String, from snapshot: Snapshot) -> URL? {
        guard let element = attachmentElement(named: filename, from: snapshot) else { return nil }

        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("Replyzen-Attachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        activateOutlook(pid: snapshot.pid)

        guard showAttachmentMenu(for: element) else {
            try? fm.removeItem(at: directory)
            return nil
        }

        Thread.sleep(forTimeInterval: 0.22)
        guard let selectedTitle = pressBestSaveAttachmentMenuItem(pid: snapshot.pid, near: element) else {
            try? fm.removeItem(at: directory)
            return nil
        }

        let lowerTitle = selectedTitle.lowercased()
        // A plain Download action usually writes to Downloads without opening a
        // Save As sheet. Let the caller's filesystem resolver pick that file up.
        if lowerTitle.contains("download") || lowerTitle.contains("herunter") {
            Thread.sleep(forTimeInterval: 1.0)
            try? fm.removeItem(at: directory)
            return nil
        }

        Thread.sleep(forTimeInterval: 0.45)
        guard hasSavePanel(pid: snapshot.pid) else {
            // Some Outlook builds save immediately. Keep a short grace period and
            // let the normal resolver discover the resulting file afterwards.
            Thread.sleep(forTimeInterval: 0.8)
            try? fm.removeItem(at: directory)
            return nil
        }

        // In the native macOS Save As sheet, Cmd+Shift+G opens "Go to Folder".
        // Set that focused field through Accessibility so no user clipboard is used.
        postKey(code: 5, flags: [.maskCommand, .maskShift]) // G
        Thread.sleep(forTimeInterval: 0.25)

        let appElement = AXUIElementCreateApplication(snapshot.pid)
        guard let focused = axElementAttribute(kAXFocusedUIElementAttribute as CFString, from: appElement),
              setValue(directory.path, on: focused) else {
            try? fm.removeItem(at: directory)
            return nil
        }

        postKey(code: 36) // Return: navigate to temp folder
        Thread.sleep(forTimeInterval: 0.35)
        postKey(code: 36) // Return: confirm Save As

        let exact = directory.appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent)
        for _ in 0..<40 {
            if fm.fileExists(atPath: exact.path),
               ((try? exact.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 {
                return exact
            }
            if let files = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ), let pdf = files.first(where: {
                $0.pathExtension.lowercased() == "pdf" &&
                (((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0)
            }) {
                return pdf
            }
            Thread.sleep(forTimeInterval: 0.10)
        }

        try? fm.removeItem(at: directory)
        return nil
    }

    private func attachmentElement(named filename: String, from snapshot: Snapshot) -> AXUIElement? {
        let needle = URL(fileURLWithPath: filename).lastPathComponent.lowercased()
        guard !needle.isEmpty else { return nil }
        let attributes: [CFString] = [
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString,
            kAXValueAttribute as CFString,
            "AXFilename" as CFString,
            "AXURL" as CFString
        ]

        var best: (AXUIElement, Int)?
        for window in snapshot.windows {
            var stack: [AXUIElement] = [window]
            var visited = 0
            while let element = stack.popLast(), visited < 24_000 {
                visited += 1
                let meta = attributes.compactMap { stringLikeAttribute($0, from: element) }
                    .joined(separator: " ")
                    .lowercased()
                if meta.contains(needle) {
                    let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
                    let score: Int
                    switch role {
                    case "AXButton", "AXLink", "AXGroup": score = 3
                    case "AXStaticText": score = 2
                    default: score = 1
                    }
                    if best == nil || score > best!.1 { best = (element, score) }
                }
                for child in children(of: element).reversed() { stack.append(child) }
            }
        }
        return best?.0
    }

    private func showAttachmentMenu(for element: AXUIElement) -> Bool {
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

    private func pressBestSaveAttachmentMenuItem(pid: pid_t, near attachment: AXUIElement) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        let saveNeedles = [
            "save attachment as", "save attachment", "save as",
            "anlage speichern unter", "anhang speichern unter", "speichern unter",
            "anlage speichern", "anhang speichern",
            "download", "herunterladen"
        ]

        let attachmentPosition = pointAttribute(kAXPositionAttribute as CFString, from: attachment) ?? .zero
        let attachmentSize = sizeAttribute(kAXSizeAttribute as CFString, from: attachment) ?? .zero
        let attachmentCenter = CGPoint(
            x: attachmentPosition.x + attachmentSize.width / 2,
            y: attachmentPosition.y + attachmentSize.height / 2
        )

        var candidates: [(AXUIElement, String, Double, Int)] = []
        var stack: [AXUIElement] = [appElement]
        var visited = 0
        while let element = stack.popLast(), visited < 28_000 {
            visited += 1
            if stringAttribute(kAXRoleAttribute as CFString, from: element) == "AXMenuItem" {
                let title = firstNonEmpty([
                    stringAttribute(kAXTitleAttribute as CFString, from: element),
                    stringAttribute(kAXDescriptionAttribute as CFString, from: element),
                    stringAttribute(kAXValueAttribute as CFString, from: element)
                ]) ?? ""
                let lower = title.lowercased()
                if let priority = saveNeedles.firstIndex(where: { lower.contains($0) }) {
                    let pos = pointAttribute(kAXPositionAttribute as CFString, from: element) ?? attachmentCenter
                    let dx = Double(pos.x - attachmentCenter.x)
                    let dy = Double(pos.y - attachmentCenter.y)
                    candidates.append((element, title, dx * dx + dy * dy, priority))
                }
            }
            for child in children(of: element).reversed() { stack.append(child) }
        }

        // Prefer explicit attachment/save-as actions; proximity breaks ties in case
        // Outlook's main menu exposes a similarly named item.
        candidates.sort {
            if $0.3 != $1.3 { return $0.3 < $1.3 }
            return $0.2 < $1.2
        }
        for candidate in candidates {
            if AXUIElementPerformAction(candidate.0, kAXPressAction as CFString) == .success {
                return candidate.1
            }
        }
        return nil
    }

    private func hasSavePanel(pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var stack: [AXUIElement] = [appElement]
        var visited = 0
        while let element = stack.popLast(), visited < 12_000 {
            visited += 1
            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            if role == "AXSheet" {
                return true
            }
            if role == "AXWindow" || role == "AXDialog" {
                let text = firstNonEmpty([
                    stringAttribute(kAXTitleAttribute as CFString, from: element),
                    stringAttribute(kAXDescriptionAttribute as CFString, from: element)
                ])?.lowercased() ?? ""
                if text.contains("save") || text.contains("speichern") || text.contains("sichern") {
                    return true
                }
            }
            for child in children(of: element).reversed() { stack.append(child) }
        }
        return false
    }

    private func postKey(code: CGKeyCode, flags: CGEventFlags = []) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
'''
if old not in s:
    raise SystemExit("activateAttachment block not found")
s = s.replace(old, new, 1)
p.write_text(s)

# 2) Payment flow: after direct AX URLs + cache lookup + open retry, automatically
# invoke Outlook Save As. Clean Replyzen temp copies after OpenAI has read them.
p = root / "app" / "AppDelegate.swift"
s = p.read_text()
old = r'''            if selectedPDFs.isEmpty, let pdfName = mentionedPDF {
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
'''
new = r'''            if selectedPDFs.isEmpty, let pdfName = mentionedPDF {
                DispatchQueue.main.sync {
                    self.state.statusText = "PDF wird aus Outlook geladen …"
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
                        self.state.statusText = "PDF wird automatisch aus Outlook gespeichert …"
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

            let replyzenTempDirectories = Set(selectedPDFs.compactMap { url -> URL? in
                guard url.path.contains("/Replyzen-Attachments/") else { return nil }
                return url.deletingLastPathComponent()
            })

            var fallbackText = ""
            var sourceStatus: String

            if !selectedPDFs.isEmpty {
                let wasAutoSaved = !replyzenTempDirectories.isEmpty
                sourceStatus = (wasAutoSaved ? "PDF automatisch aus Outlook gespeichert und direkt mit OpenAI gelesen: " : "PDF direkt mit OpenAI gelesen: ")
                    + selectedPDFs.map(\.lastPathComponent).joined(separator: ", ")
                DispatchQueue.main.async {
                    self.state.statusText = "PDF wird direkt an OpenAI übergeben und gelesen …"
                }
            } else {
'''
if old not in s:
    raise SystemExit("payment retry block not found")
s = s.replace(old, new, 1)

old = r'''                } else if pdfMentioned {
                    sourceStatus = "PDF-Anhang erkannt, aber Outlook hat keine lokale Datei bereitgestellt. Bitte den PDF-Anhang einmal in Outlook öffnen und erneut auf Überweisung klicken."
                } else {
'''
new = r'''                } else if pdfMentioned {
                    sourceStatus = "PDF-Anhang erkannt, aber Outlook konnte ihn weder lokal bereitstellen noch automatisch speichern."
                } else {
'''
if old not in s:
    raise SystemExit("payment fallback status block not found")
s = s.replace(old, new, 1)

old = r'''            ) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRunningFlow = false

                    switch result {
'''
new = r'''            ) { [weak self] result in
                // OpenAI has completed reading/uploading at this point, so any
                // temporary Outlook Save As copies can be removed immediately.
                for directory in replyzenTempDirectories {
                    try? FileManager.default.removeItem(at: directory)
                }

                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRunningFlow = false

                    switch result {
'''
# Replace only the occurrence after createPaymentSuggestion. Use rfind around payment section.
payment_pos = s.find('self.openAI.createPaymentSuggestion(')
if payment_pos < 0:
    raise SystemExit("createPaymentSuggestion call not found")
idx = s.find(old, payment_pos)
if idx < 0:
    raise SystemExit("payment completion block not found")
s = s[:idx] + new + s[idx+len(old):]
p.write_text(s)

# 3) Version metadata.
p = root / "app" / "Info.plist"
s = p.read_text()
s = s.replace('<string>1.39.0</string>', '<string>1.40.0</string>', 1)
s = s.replace('<string>40</string>', '<string>41</string>', 1)
p.write_text(s)

p = root / "Build-CI.sh"
s = p.read_text()
s = s.replace('Replyzen-update-1.39.zip', 'Replyzen-update-1.40.zip')
s = s.replace(
    'Replyzen 1.39: Im Outlook Overlay trennt nur noch ein Pipe Forward von den kontextuellen Aktionen Cancel, Calendar und Payment. Tooltips erscheinen nach 0,75 Sekunden und der Overlay Hintergrund hebt sich deutlicher von Outlook ab. Die Mail Form ist deutlich kompakter, das WYSIWYG Textfeld größer und die große graue Leerfläche entfernt.',
    'Replyzen 1.40: Payment materialisiert PDF-Anhänge deutlich robuster. Replyzen versucht zuerst direkte Outlook-Datei-URLs und Cache-Dateien, öffnet den Anhang über die vollständige Accessibility-Elternkette und nutzt als letzten automatischen Fallback Outlooks eigenes Save-As-Menü in einen temporären Replyzen-Ordner. Die temporäre PDF wird nach der OpenAI-Auswertung gelöscht.'
)
p.write_text(s)
