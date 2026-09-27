import AppKit
import ApplicationServices

/// Reply-only transport. Does not send mail, rebuild messages or touch attachments.
final class OutlookReplyInsertion {
    private let outlook: OutlookAccessibility
    private let keyboard = KeyboardController()
    private let snapshot: OutlookAccessibility.Snapshot
    private let replyAll: Bool
    private let note: String
    private let html: String
    private let reminder: String?
    private let completion: (String?) -> Void
    private var state: ReplyInsertionState?
    private var cancelled = false
    private var initialWindows: [AXUIElement] = []
    private var originalBodies: [AXUIElement] = []
    private var targetWindow: AXUIElement?
    private var editor: AXUIElement?
    private var sendControl: AXUIElement?
    private var prepared = false
    private var focusAttempts = 0
    private var pasted = false

    init(outlook: OutlookAccessibility, snapshot: OutlookAccessibility.Snapshot,
         replyAll: Bool, note: String, html: String, reminder: String?,
         completion: @escaping (String?) -> Void) {
        self.outlook = outlook
        self.snapshot = snapshot
        self.replyAll = replyAll
        self.note = note
        self.html = html
        self.reminder = reminder
        self.completion = completion
    }

    func cancel() { cancelled = true }

    func start() {
        let app = AXUIElementCreateApplication(snapshot.pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        initialWindows = elements(app, "AXWindows")
        if let source = snapshot.windows.first {
            originalBodies = walk(source).filter { isBodyRole($0) }
        }
        let accepted = outlook.openReplyComposer(replyAll: replyAll, from: snapshot)
        state = ReplyInsertionState(note: note, nativeOpenAccepted: accepted)
        scheduleTick()
    }

    private func scheduleTick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.tick() }
    }

    private func tick() {
        guard !cancelled else { return }
        let observation = observe()
        guard var currentState = state else { return }
        let action = currentState.next(observation)
        state = currentState
        switch action {
        case .wait: break
        case .keyboardFallback:
            // Only once, only if the native control did not acknowledge opening,
            // and only while the original source window is still focused.
            guard let focused = focusedWindow(), let source = snapshot.windows.first,
                  CFEqual(focused, source) else { finish("R71-WINDOW"); return }
            if replyAll { keyboard.sendCommandShiftR() } else { keyboard.sendCommandR() }
        case .focus:
            if !prepared {
                prepared = true
                if let reminder { _ = outlook.setComposeBCCValue(reminder) }
            }
            requestEditorFocus()
        case .position:
            guard let editor, hasEditorFocus() else { break }
            var range = CFRange(location: 0, length: 0)
            if let value = AXValueCreate(.cfRange, &range),
               AXUIElementSetAttributeValue(editor, "AXSelectedTextRange" as CFString, value) == .success {
                break
            }
            keyboard.sendCommandUp()
        case .paste:
            // Check again at the write boundary; AX focus requests alone are not proof.
            guard !pasted, isOutlookActive(), hasEditorFocus() else { finish("R71-FOCUS"); return }
            pasted = true
            MailTypography.write(plainText: note + "\n\n", html: html.isEmpty ? "" : html + "<br><br>")
            keyboard.sendCommandV()
        case .complete:
            finish(nil); return
        case .fail(let code):
            finish(code); return
        }
        scheduleTick()
    }

    private func finish(_ errorCode: String?) {
        guard !cancelled else { return }
        cancelled = true
        completion(errorCode)
    }

    private func observe() -> ReplyInsertionState.Observation {
        var result = ReplyInsertionState.Observation()
        result.active = isOutlookActive()
        guard result.active, let window = focusedWindow() else { return result }
        if let targetWindow, !CFEqual(targetWindow, window) {
            result.targetChanged = true
            return result
        }
        if targetWindow == nil,
           initialWindows.contains(where: { CFEqual($0, window) }),
           !snapshot.windows.prefix(1).contains(where: { CFEqual($0, window) }) {
            result.targetChanged = true
            return result
        }
        let cachedIsValid = editor.map { isBodyRole($0) && isDescendant($0, of: window) } == true
            && sendControl.map { isDescendant($0, of: window) } == true
        if cachedIsValid {
            result.composer = true
        } else {
            let sendControls = walk(window).filter { node in
                let role = text(node, "AXRole") ?? ""
                guard role == "AXButton" || role == "AXMenuButton" else { return false }
                return ["AXTitle", "AXDescription", "AXHelp"].compactMap { text(node, $0) }
                    .contains(where: ReplyInsertionPolicy.isSendControl)
            }
            result.composer = !sendControls.isEmpty
            guard result.composer else { return result }
            if targetWindow == nil { targetWindow = window }
            sendControl = sendControls.first
            editor = resolveEditor(sendControls: sendControls, window: window)
        }
        result.editor = editor != nil
        result.focused = hasEditorFocus()
        if let editor {
            result.text = bodyText(editor)
            if let rawRange = raw(editor, "AXSelectedTextRange"), CFGetTypeID(rawRange) == AXValueGetTypeID() {
                let value = rawRange as! AXValue
                var range = CFRange()
                if AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range) {
                    result.caretAtStart = range.location == 0 && range.length == 0
                }
            }
        }
        return result
    }

    private func resolveEditor(sendControls: [AXUIElement], window: AXUIElement) -> AXUIElement? {
        for send in sendControls {
            var region = element(send, "AXParent")
            for _ in 0..<12 {
                guard let scope = region else { break }
                var best: (AXUIElement, Double)?
                for candidate in walk(scope) where isBodyRole(candidate) {
                    let metadata = ["AXTitle", "AXDescription", "AXHelp", "AXPlaceholderValue", "AXRoleDescription"]
                        .compactMap { text(candidate, $0) }.joined(separator: " ").lowercased()
                    if ["subject", "betreff", "asunto", "search", "suchen", "recipient", "empfanger", "bcc", "attachment preview"].contains(where: { metadata.contains($0) }) { continue }
                    let named = ["message body", "mail body", "nachrichtentext", "compose body", "cuerpo del mensaje", "cuerpo del correo", "rich text", "html content"].contains(where: { metadata.contains($0) })
                    let editable = bool(candidate, "AXEditable") == true || settable(candidate, "AXValue")
                    let wasReadPane = originalBodies.contains { CFEqual($0, candidate) }
                    let rect = frame(candidate)
                    guard named || (rect.width > 180 && rect.height > 50) else { continue }
                    guard let score = ReplyInsertionPolicy.bodyScore(named: named, editable: editable,
                            wasReadPane: wasReadPane, area: Double(rect.width * rect.height)) else { continue }
                    if best == nil || score > best!.1 { best = (candidate, score) }
                }
                if let best { return best.0 }
                if CFEqual(scope, window) { break }
                region = element(scope, "AXParent")
            }
        }
        return nil
    }

    private func requestEditorFocus() {
        guard let editor, isOutlookActive() else { return }
        focusAttempts += 1
        _ = AXUIElementSetAttributeValue(editor, "AXFocused" as CFString, kCFBooleanTrue)
        guard focusAttempts >= 3, !hasEditorFocus() else { return }
        // AX can acknowledge focus without moving the real keyboard focus. Click
        // only after hit-testing that the point belongs to this exact body subtree.
        let rect = frame(editor)
        guard rect.width > 20 && rect.height > 20 else { return }
        let point = CGPoint(x: rect.minX + min(24, rect.width / 2), y: rect.minY + min(16, rect.height / 2))
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit, isDescendant(hit, of: editor), let source = CGEventSource(stateID: .hidSystemState) else { return }
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func hasEditorFocus() -> Bool {
        guard isOutlookActive(), let editor, let targetWindow,
              let window = focusedWindow(), CFEqual(targetWindow, window),
              let focused = element(AXUIElementCreateApplication(snapshot.pid), "AXFocusedUIElement") else { return false }
        return isDescendant(focused, of: editor)
    }

    private func isDescendant(_ child: AXUIElement, of root: AXUIElement) -> Bool {
        var cursor: AXUIElement? = child
        for _ in 0..<24 {
            guard let current = cursor else { return false }
            if CFEqual(current, root) { return true }
            cursor = element(current, "AXParent")
        }
        return false
    }

    private func bodyText(_ node: AXUIElement) -> String? {
        if let value = text(node, "AXValue"), !value.isEmpty { return value }
        var pieces: [String] = []
        for child in walk(node) where !CFEqual(child, node) {
            let role = text(child, "AXRole") ?? ""
            if role == "AXStaticText" || role == "AXTextArea" {
                if let value = text(child, "AXValue"), !value.isEmpty { pieces.append(value) }
                else if let value = text(child, "AXTitle"), !value.isEmpty { pieces.append(value) }
            }
        }
        if !pieces.isEmpty { return pieces.joined(separator: "\n") }
        // An explicitly readable empty body is distinct from a failed AX read.
        return text(node, "AXValue")
    }

    private func isOutlookActive() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid
    }
    private func focusedWindow() -> AXUIElement? {
        element(AXUIElementCreateApplication(snapshot.pid), "AXFocusedWindow")
    }
    private func isBodyRole(_ node: AXUIElement) -> Bool {
        let role = text(node, "AXRole") ?? ""
        return role == "AXTextArea" || role == "AXWebArea"
    }
    private func raw(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success else { return nil }
        return value
    }
    private func text(_ node: AXUIElement, _ key: String) -> String? {
        let value = raw(node, key)
        if let value = value as? String { return value }
        if let value = value as? NSAttributedString { return value.string }
        return nil
    }
    private func bool(_ node: AXUIElement, _ key: String) -> Bool? { raw(node, key) as? Bool }
    private func element(_ node: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = raw(node, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return value as! AXUIElement
    }
    private func elements(_ node: AXUIElement, _ key: String) -> [AXUIElement] { raw(node, key) as? [AXUIElement] ?? [] }
    private func settable(_ node: AXUIElement, _ key: String) -> Bool {
        var value = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(node, key as CFString, &value) == .success && value.boolValue
    }
    private func walk(_ root: AXUIElement) -> [AXUIElement] {
        var stack = [root], result: [AXUIElement] = []
        var seen = Set<CFHashCode>()
        while let node = stack.popLast(), result.count < 2_000 {
            guard seen.insert(CFHash(node)).inserted else { continue }
            result.append(node)
            stack.append(contentsOf: elements(node, "AXChildren").reversed())
        }
        return result
    }
    private func frame(_ node: AXUIElement) -> CGRect {
        guard let p = raw(node, "AXPosition"), let s = raw(node, "AXSize"),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return .zero }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return .zero }
        return CGRect(origin: point, size: size)
    }
}
