import Foundation

/// Failure-only metadata. Deliberately accepts no message text, subject,
/// window title, application path, clipboard contents or account information.
enum ReplyFocusDiagnostic {
    struct Application: Equatable {
        let pid: Int32
        let name: String?
        let bundleID: String?

        var summary: String {
            "\(safe(name)) [\(safe(bundleID))] pid=\(pid)"
        }
    }

    struct Report {
        let version: String
        let observed: Application?
        let current: Application?
        let expected: Application?
        let expectedPID: Int32
        let selfPID: Int32
        let accessibilityApplication: Application?
        let accessibilityStatus: Int32
        let focusedElementPID: Int32?
        let focusedElementRole: String?
        let windowRelation: String
        let pasteRequested: Bool
        let ownInteractiveWindow: Bool
        let outlookPIDs: [Int32]
        let replyzenPIDs: [Int32]

        var text: String {
            [
                "FOCUS-D1 / \(safe(version))",
                "observed: \(observed?.summary ?? "unavailable")",
                "expected: \(expected?.summary ?? "not running") / saved-pid=\(expectedPID); self-pid=\(selfPID)",
                "now: \(current?.summary ?? "unavailable")",
                "AX-app: \(accessibilityApplication?.summary ?? "unavailable") / status=\(accessibilityStatus); AX-element=\(focusedElementPID.map(String.init) ?? "unavailable") / \(safe(focusedElementRole))",
                "window=\(safe(windowRelation)); paste-requested=\(pasteRequested); own-ui=\(ownInteractiveWindow); Outlook-pids=\(outlookPIDs.sorted()); ReplyZen-pids=\(replyzenPIDs.sorted())"
            ].joined(separator: "\n")
        }
    }

    private static func safe(_ value: String?) -> String {
        guard let value else { return "unknown" }
        let clean = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(clean)).prefix(100).description
    }
}

#if canImport(AppKit)
import AppKit
import ApplicationServices

extension ReplyFocusDiagnostic {
    /// Invoked only after the unchanged foreground guard has decided to abort,
    /// and before the error panel is shown. `observed` is the ORIGINAL sample
    /// used by that guard, not a new sample read after displaying our own UI.
    static func capture(observed: NSRunningApplication?, expectedPID: pid_t,
                        sourceWindow: AXUIElement?, targetWindow: AXUIElement?,
                        pasteRequested: Bool, ownInteractiveWindow: Bool) -> String {
        func metadata(_ app: NSRunningApplication?) -> Application? {
            guard let app else { return nil }
            return Application(pid: app.processIdentifier, name: app.localizedName,
                               bundleID: app.bundleIdentifier)
        }
        func attribute(_ node: AXUIElement, _ name: String) -> (CFTypeRef?, AXError) {
            var result: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(node, name as CFString, &result)
            return (result, status)
        }
        func asElement(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        func processID(_ element: AXUIElement?) -> pid_t? {
            guard let element else { return nil }
            var pid: pid_t = 0
            return AXUIElementGetPid(element, &pid) == .success ? pid : nil
        }

        // Freeze names/PIDs while still on the failing call stack.
        let sampled = metadata(observed)
        let current = metadata(NSWorkspace.shared.frontmostApplication)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        let (axValue, axStatus) = attribute(system, "AXFocusedApplication")
        let axPID = processID(asElement(axValue))
        let axApplication = axPID.map { pid in
            metadata(NSRunningApplication(processIdentifier: pid))
                ?? Application(pid: pid, name: nil, bundleID: nil)
        }
        let focusedElement = asElement(attribute(system, "AXFocusedUIElement").0)
        let focusedPID = processID(focusedElement)
        let role = focusedElement.flatMap { attribute($0, "AXRole").0 as? String }
        let expectedAX = AXUIElementCreateApplication(expectedPID)
        AXUIElementSetMessagingTimeout(expectedAX, 0.15)
        let window = asElement(attribute(expectedAX, "AXFocusedWindow").0)
        let relation: String
        if let window, let targetWindow, CFEqual(window, targetWindow) { relation = "target" }
        else if let window, let sourceWindow, CFEqual(window, sourceWindow) { relation = "source" }
        else { relation = window == nil ? "unavailable" : "other" }
        let running = NSWorkspace.shared.runningApplications
        let ownID = Bundle.main.bundleIdentifier
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return Report(version: "\(version) (\(build))", observed: sampled, current: current,
            expected: metadata(NSRunningApplication(processIdentifier: expectedPID)),
            expectedPID: expectedPID, selfPID: ProcessInfo.processInfo.processIdentifier,
            accessibilityApplication: axApplication, accessibilityStatus: axStatus.rawValue,
            focusedElementPID: focusedPID, focusedElementRole: role,
            windowRelation: relation, pasteRequested: pasteRequested,
            ownInteractiveWindow: ownInteractiveWindow,
            outlookPIDs: running.filter { $0.bundleIdentifier == "com.microsoft.Outlook" }.map(\.processIdentifier),
            replyzenPIDs: running.filter { ownID != nil && $0.bundleIdentifier == ownID }.map(\.processIdentifier)
        ).text
    }
}
#endif
