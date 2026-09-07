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
                return "Microsoft Outlook läuft nicht."
            case .noWindow:
                return "Ich finde kein Outlook-Fenster. Öffne die Mail bitte sichtbar in Outlook."
            case .noMailText:
                return "Ich konnte in der geöffneten Outlook-Mail keinen lesbaren Mailtext finden."
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

    func runningPID() -> pid_t? {
        NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.microsoft.Outlook" })?.processIdentifier
    }

    func activateOutlook(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
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

    private func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
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
