import AppKit
import ApplicationServices

final class OutlookAccessibility {
    struct Snapshot {
        let pid: pid_t
        let windows: [AXUIElement]
    }

    enum OutlookError: LocalizedError {
        case notRunning
        case noWindow
        case noMailText

        var errorDescription: String? {
            switch self {
            case .notRunning:
                return L10n.source("Microsoft Outlook läuft nicht.")
            case .noWindow:
                return L10n.source("Ich finde kein Outlook-Fenster. Öffne die Mail bitte sichtbar in Outlook.")
            case .noMailText:
                return L10n.source("Ich konnte in der geöffneten Outlook-Mail keinen lesbaren Mailtext finden.")
            }
        }
    }

    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func requestTrustPrompt() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func captureSnapshot(includeAllWindows: Bool = false) throws -> Snapshot {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.microsoft.Outlook" }) else {
            throw OutlookError.notRunning
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windows: [AXUIElement] = []

        if let focused = axElementAttribute(kAXFocusedWindowAttribute as CFString, from: appElement) {
            windows.append(focused)
        }

        if includeAllWindows || windows.isEmpty,
           let all = axElementsAttribute(kAXWindowsAttribute as CFString, from: appElement) {
            for window in all where !containsSameElement(windows, window) {
                windows.append(window)
            }
        }

        guard !windows.isEmpty else { throw OutlookError.noWindow }
        return Snapshot(pid: app.processIdentifier, windows: windows)
    }

    func readMail(from snapshot: Snapshot) throws -> String {
        var best = ""

        for window in snapshot.windows {
            let webAreas = findElements(role: "AXWebArea", root: window, maxNodes: 18_000)
            for webArea in webAreas {
                let text = collectStaticText(root: webArea, maxNodes: 18_000)
                if text.count > best.count {
                    best = text
                }
            }
        }

        let cleaned = cleanup(best)
        guard cleaned.count > 20 else { throw OutlookError.noMailText }
        return cleaned
    }


    func attachmentFilenames(from snapshot: Snapshot) -> [String] {
        let pattern = #"(?i)([^/\\\n\r\t<>:\"|?*]{1,180}\.(?:pdf|png|jpe?g|tiff?))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let attributes: [CFString] = [
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString,
            kAXValueAttribute as CFString,
            "AXFilename" as CFString,
            "AXURL" as CFString
        ]
        var names: [String] = []
        var seen = Set<String>()

        for window in snapshot.windows {
            var stack: [AXUIElement] = [window]
            var visited = 0
            while let element = stack.popLast(), visited < 18_000 {
                visited += 1
                for attribute in attributes {
                    guard let raw = stringLikeAttribute(attribute, from: element), !raw.isEmpty else { continue }
                    let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
                    for match in regex.matches(in: raw, range: range) {
                        guard match.numberOfRanges > 1,
                              let matchRange = Range(match.range(at: 1), in: raw) else { continue }
                        let name = String(raw[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let key = name.lowercased()
                        if !name.isEmpty && !seen.contains(key) {
                            seen.insert(key)
                            names.append(name)
                        }
                    }
                }
                for child in children(of: element).reversed() { stack.append(child) }
            }
        }
        return Array(names.prefix(6))
    }

    func attachmentFileURLs(from snapshot: Snapshot) -> [URL] {
        let attributes: [CFString] = [
            "AXURL" as CFString,
            "AXFilename" as CFString,
            kAXValueAttribute as CFString,
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString
        ]
        var urls: [URL] = []
        var seen = Set<String>()
        let fm = FileManager.default

        for window in snapshot.windows {
            var stack: [AXUIElement] = [window]
            var visited = 0
            while let element = stack.popLast(), visited < 20_000 {
                visited += 1
                for attribute in attributes {
                    guard let raw = stringLikeAttribute(attribute, from: element), !raw.isEmpty else { continue }
                    for url in localAttachmentURLs(from: raw) {
                        let ext = url.pathExtension.lowercased()
                        guard ["pdf", "png", "jpg", "jpeg", "tif", "tiff"].contains(ext),
                              fm.fileExists(atPath: url.path) else { continue }
                        let key = url.standardizedFileURL.path.lowercased()
                        if seen.insert(key).inserted {
                            urls.append(url.standardizedFileURL)
                        }
                    }
                }
                for child in children(of: element).reversed() { stack.append(child) }
            }
        }
        return Array(urls.prefix(8))
    }

    func openSelectedMessageWindowIfNeeded(from snapshot: Snapshot) -> Snapshot {
        guard let focusedWindow = snapshot.windows.first,
              looksLikeMainOutlookWindow(focusedWindow) else {
            return snapshot
        }

        activateOutlook(pid: snapshot.pid)
        focusSelectedMessageRow(in: focusedWindow)
        postKey(code: 36) // Return opens the selected message in Legacy Outlook.
        Thread.sleep(forTimeInterval: 0.95)

        return (try? captureSnapshot(includeAllWindows: true)) ?? snapshot
    }

    private func looksLikeMainOutlookWindow(_ window: AXUIElement) -> Bool {
        // The mailbox window contains a large outline/table outside the message
        // web area. A standalone message window normally does not.
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0

        while let (element, depth) = stack.popLast(), visited < 10_000 {
            visited += 1
            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""

            if role == "AXWebArea" { continue }

            if depth <= 9 && (role == "AXOutline" || role == "AXTable") {
                if let size = sizeAttribute(kAXSizeAttribute as CFString, from: element),
                   size.width > 180, size.height > 180 {
                    return true
                }
            }

            if depth < 10 {
                for child in children(of: element).reversed() {
                    stack.append((child, depth + 1))
                }
            }
        }
        return false
    }

    private func focusSelectedMessageRow(in window: AXUIElement) {
        var stack: [AXUIElement] = [window]
        var visited = 0
        while let element = stack.popLast(), visited < 12_000 {
            visited += 1
            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            if role == "AXRow", boolAttribute(kAXSelectedAttribute as CFString, from: element) == true {
                _ = focus(element)
                return
            }
            if role != "AXWebArea" {
                for child in children(of: element).reversed() { stack.append(child) }
            }
        }
    }

    func activateAttachment(named filename: String, from snapshot: Snapshot) -> Bool {
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

        Thread.sleep(forTimeInterval: 0.48)
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

    private func localAttachmentURLs(from raw: String) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL?) {
            guard let url, url.isFileURL else { return }
            let standardized = url.standardizedFileURL
            let key = standardized.path.lowercased()
            if seen.insert(key).inserted { result.append(standardized) }
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = URL(string: trimmed), direct.isFileURL {
            append(direct)
        }

        let decoded = trimmed.removingPercentEncoding ?? trimmed
        if decoded.hasPrefix("/") {
            append(URL(fileURLWithPath: decoded))
        }

        let pattern = #"file://[^\s\"'<>]+\.(?:pdf|png|jpe?g|tiff?)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            for match in regex.matches(in: trimmed, range: range) {
                guard let r = Range(match.range, in: trimmed) else { continue }
                append(URL(string: String(trimmed[r])))
            }
        }
        return result
    }

    func runningPID() -> pid_t? {
        NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.microsoft.Outlook" })?.processIdentifier
    }

    func activateOutlook(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    func setComposeBCCValue(_ bcc: String) -> Bool {
        guard let window = focusedOutlookWindow() else { return false }
        if let element = composeBCCElement(in: window) {
            return setValue(bcc, on: element)
        }

        // Some Outlook layouts hide BCC until its small Bcc control is pressed.
        // Reveal it once, then resolve the actual BCC field again by accessibility metadata.
        if pressComposeControl(in: window, matching: ["bcc", "blind carbon", "blind copy", "blindkopie"]) ,
           let refreshed = focusedOutlookWindow(),
           let element = composeBCCElement(in: refreshed) {
            return setValue(bcc, on: element)
        }
        return false
    }

    func setComposeSubjectValue(_ subject: String) -> Bool {
        guard let window = focusedOutlookWindow(), let element = composeSubjectElement(in: window) else { return false }
        return setValue(subject, on: element)
    }

    func setComposeBodyValue(_ body: String) -> Bool {
        guard let window = focusedOutlookWindow(), let element = composeBodyElement(in: window) else { return false }
        return setValue(body, on: element)
    }

    func focusComposeSubjectField() -> Bool {
        guard let window = focusedOutlookWindow(), let element = composeSubjectElement(in: window) else { return false }
        return focus(element)
    }

    func focusComposeBodyField() -> Bool {
        guard let window = focusedOutlookWindow(), let element = composeBodyElement(in: window) else { return false }
        return focus(element)
    }

    private func focusedOutlookWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.microsoft.Outlook" }) else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return axElementAttribute(kAXFocusedWindowAttribute as CFString, from: appElement)
    }

    private func composeBCCElement(in window: AXUIElement) -> AXUIElement? {
        var stack: [AXUIElement] = [window]
        var visited = 0
        while let element = stack.popLast(), visited < 14_000 {
            visited += 1
            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" {
                let meta = composeMetadata(for: element)
                if meta.contains("bcc") || meta.contains("blind carbon") || meta.contains("blind copy") || meta.contains("blindkopie") {
                    return element
                }
            }
            for child in children(of: element).reversed() { stack.append(child) }
        }
        return nil
    }

    private func pressComposeControl(in window: AXUIElement, matching needles: [String]) -> Bool {
        var stack: [AXUIElement] = [window]
        var visited = 0
        while let element = stack.popLast(), visited < 14_000 {
            visited += 1
            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            if role == "AXButton" || role == "AXCheckBox" || role == "AXMenuButton" {
                let meta = composeMetadata(for: element)
                if needles.contains(where: { meta.contains($0) }) {
                    if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                        return true
                    }
                }
            }
            for child in children(of: element).reversed() { stack.append(child) }
        }
        return false
    }

    private func composeSubjectElement(in window: AXUIElement) -> AXUIElement? {
        var stack: [AXUIElement] = [window]
        var visited = 0
        var fallback: [(AXUIElement, CGFloat)] = []
        let windowY = pointAttribute(kAXPositionAttribute as CFString, from: window)?.y ?? 0
        let windowHeight = sizeAttribute(kAXSizeAttribute as CFString, from: window)?.height ?? 900

        while let element = stack.popLast(), visited < 14_000 {
            visited += 1
            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" {
                let meta = composeMetadata(for: element)
                if meta.contains("subject") || meta.contains("betreff") {
                    return element
                }

                if isValueSettable(element),
                   let size = sizeAttribute(kAXSizeAttribute as CFString, from: element),
                   let pos = pointAttribute(kAXPositionAttribute as CFString, from: element),
                   size.width > 260, size.height < 90,
                   pos.y < windowY + windowHeight * 0.55 {
                    fallback.append((element, pos.y))
                }
            }
            for child in children(of: element).reversed() { stack.append(child) }
        }

        // In compose windows the subject field is normally the lowest wide editable single-line field
        // below To/Cc/Bcc, so use it as a language-independent fallback.
        return fallback.max(by: { $0.1 < $1.1 })?.0
    }

    private func composeBodyElement(in window: AXUIElement) -> AXUIElement? {
        var stack: [AXUIElement] = [window]
        var visited = 0
        var best: (AXUIElement, CGFloat)?

        while let element = stack.popLast(), visited < 14_000 {
            visited += 1
            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            if role == "AXTextArea" || role == "AXWebArea" {
                let meta = composeMetadata(for: element)
                if meta.contains("message body") || meta.contains("mail body") || meta.contains("nachrichtentext") || meta.contains("compose body") {
                    return element
                }

                if let size = sizeAttribute(kAXSizeAttribute as CFString, from: element),
                   size.width > 300, size.height > 120 {
                    let area = size.width * size.height
                    if best == nil || area > best!.1 { best = (element, area) }
                }
            }
            for child in children(of: element).reversed() { stack.append(child) }
        }
        return best?.0
    }

    private func composeMetadata(for element: AXUIElement) -> String {
        let attrs: [CFString] = [
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString,
            "AXPlaceholderValue" as CFString,
            "AXIdentifier" as CFString,
            "AXDOMIdentifier" as CFString,
            "AXRoleDescription" as CFString
        ]
        return attrs.compactMap { stringAttribute($0, from: element) }
            .joined(separator: " ")
            .lowercased()
    }

    private func isValueSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    private func setValue(_ value: String, on element: AXUIElement) -> Bool {
        guard isValueSettable(element) else { return false }
        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef) == .success
    }

    private func focus(_ element: AXUIElement) -> Bool {
        if AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            return true
        }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    func focusedWindowFrameInAppKitCoordinates() -> CGRect? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.microsoft.Outlook" }) else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = axElementAttribute(kAXFocusedWindowAttribute as CFString, from: appElement),
              let axPosition = pointAttribute(kAXPositionAttribute as CFString, from: window),
              let axSize = sizeAttribute(kAXSizeAttribute as CFString, from: window) else {
            return nil
        }

        let axCenter = CGPoint(x: axPosition.x + axSize.width / 2, y: axPosition.y + axSize.height / 2)

        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            let quartzBounds = CGDisplayBounds(displayID)

            if quartzBounds.contains(axCenter) {
                let localX = axPosition.x - quartzBounds.minX
                let localYFromTop = axPosition.y - quartzBounds.minY
                let x = screen.frame.minX + localX
                let y = screen.frame.maxY - localYFromTop - axSize.height
                return CGRect(x: x, y: y, width: axSize.width, height: axSize.height)
            }
        }

        if let main = NSScreen.main {
            let x = main.frame.minX + axPosition.x
            let y = main.frame.maxY - axPosition.y - axSize.height
            return CGRect(x: x, y: y, width: axSize.width, height: axSize.height)
        }

        return nil
    }

    private func findElements(role targetRole: String, root: AXUIElement, maxNodes: Int) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var stack: [AXUIElement] = [root]
        var visited = 0

        while let element = stack.popLast(), visited < maxNodes {
            visited += 1
            if stringAttribute(kAXRoleAttribute as CFString, from: element) == targetRole {
                result.append(element)
            }

            let children = children(of: element)
            for child in children.reversed() {
                stack.append(child)
            }
        }
        return result
    }

    private func collectStaticText(root: AXUIElement, maxNodes: Int) -> String {
        var lines: [String] = []
        var stack: [AXUIElement] = [root]
        var visited = 0

        while let element = stack.popLast(), visited < maxNodes {
            visited += 1
            let role = stringAttribute(kAXRoleAttribute as CFString, from: element)

            if role == "AXStaticText" || role == "AXTextArea" {
                let text = firstNonEmpty([
                    stringAttribute(kAXValueAttribute as CFString, from: element),
                    stringAttribute(kAXTitleAttribute as CFString, from: element),
                    stringAttribute(kAXDescriptionAttribute as CFString, from: element)
                ])

                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if lines.last != text {
                        lines.append(text)
                    }
                }
            }

            for child in children(of: element).reversed() {
                stack.append(child)
            }
        }

        return lines.joined(separator: "\n")
    }

    private func cleanup(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firstNonEmpty(_ strings: [String?]) -> String? {
        strings.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        if let children = axElementsAttribute(kAXChildrenAttribute as CFString, from: element), !children.isEmpty {
            return children
        }
        if let visible = axElementsAttribute(kAXVisibleChildrenAttribute as CFString, from: element) {
            return visible
        }
        return []
    }

    private func boolAttribute(_ attribute: CFString, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }



    private func stringLikeAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success, let value else { return nil }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        if let url = value as? NSURL { return url.absoluteString }
        return nil
    }

    private func pointAttribute(_ attribute: CFString, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ attribute: CFString, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private func axElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func axElementsAttribute(_ attribute: CFString, from element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let array = value as? [AXUIElement] else { return nil }
        return array
    }

    private func containsSameElement(_ array: [AXUIElement], _ candidate: AXUIElement) -> Bool {
        array.contains { CFEqual($0, candidate) }
    }
}
