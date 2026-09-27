import Foundation

/// Shared by the real AX adapter and deterministic tests. No mail content is logged.
enum ReplyInsertionPolicy {
    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func isSendControl(_ label: String) -> Bool {
        let value = normalized(label).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        // The old contains("send") check also matched Send/Receive in the read pane.
        let excluded = ["receive", "empfang", "recibir", "recevoir", "later", "spater", "programar", "undo", "ruckgangig", "deshacer"]
        guard !excluded.contains(where: { value.contains($0) }) else { return false }
        let labels = ["send", "send message", "send email", "send mail", "send now", "senden", "nachricht senden", "e-mail senden", "jetzt senden", "enviar", "enviar mensaje", "enviar correo"]
        return labels.contains { value == $0 || value.hasPrefix($0 + " (") || value.hasPrefix($0 + " \u{2318}") }
    }

    static func bodyScore(named: Bool, editable: Bool, wasReadPane: Bool, area: Double) -> Double? {
        // Selection support alone is NOT proof of editability: read panes select text too.
        guard !wasReadPane || editable else { return nil }
        guard named || editable else { return nil }
        return (named ? 1_000_000_000 : 0) + (editable ? 100_000_000 : 0) + min(area, 10_000_000)
    }

    static func confirmsInsertion(note: String, before: String?, after: String?) -> Bool {
        guard let before, let after else { return false }
        let wanted = normalized(note), old = normalized(before), current = normalized(after)
        guard !wanted.isEmpty, current != old, current.hasPrefix(wanted) else { return false }
        // Do not confuse identical words already in the quoted thread with a new insertion.
        return current.count >= old.count + wanted.count
    }
}

struct ReplyInsertionState {
    struct Observation {
        var active = true
        var targetChanged = false
        var windowPending = false
        var editorRebound = false
        var composer = false
        var editor = false
        var focused = false
        var caretAtStart: Bool? = nil
        var text: String? = nil
    }
    enum Action: Equatable {
        case wait, keyboardFallback, focus, position, paste, complete
        case fail(String)
    }
    private enum Phase { case opening, focusing, positioning, verifying, done }
    private var phase: Phase = .opening
    private var phaseTicks = 0
    private var totalTicks = 0
    private var fallbackUsed = false
    private var confirmations = 0
    private var before: String?
    let note: String
    let nativeOpenAccepted: Bool

    init(note: String, nativeOpenAccepted: Bool) {
        self.note = note
        self.nativeOpenAccepted = nativeOpenAccepted
    }

    mutating func next(_ observation: Observation) -> Action {
        guard phase != .done else { return .wait }
        totalTicks += 1
        phaseTicks += 1
        if observation.targetChanged { return fail("R74-WINDOW") }
        if !observation.active { return fail("R74-FOCUS") }
        if totalTicks > 100 { return fail("R74-TIMEOUT") }
        if observation.windowPending {
            if phase == .verifying && phaseTicks > 25 { return fail("R74-VERIFY") }
            if phase != .verifying { phaseTicks = max(0, phaseTicks - 1) }
            return .wait
        }
        if observation.editorRebound && phase != .verifying {
            phase = .opening
            phaseTicks = 0
            before = nil
            confirmations = 0
        }
        switch phase {
        case .opening:
            if observation.composer && observation.editor {
                phase = .focusing; phaseTicks = 0
                return .focus
            }
            if phaseTicks > 50 { return fail("R74-EDITOR") }
            if !observation.composer && !nativeOpenAccepted && !fallbackUsed && phaseTicks >= 8 {
                fallbackUsed = true
                return .keyboardFallback
            }
            return .wait
        case .focusing:
            guard observation.composer && observation.editor else {
                return phaseTicks > 30 ? fail("R74-EDITOR") : .wait
            }
            if observation.focused {
                phase = .positioning; phaseTicks = 0
                return .position
            }
            return phaseTicks > 20 ? fail("R74-FOCUS") : .focus
        case .positioning:
            guard observation.composer && observation.editor && observation.focused else {
                phase = .focusing; phaseTicks = 0
                return .wait
            }
            if phaseTicks > 10 { return fail("R74-CARET") }
            if observation.caretAtStart == false { return .position }
            // Allow a run-loop turn even after AX accepted the caret change.
            if phaseTicks < 2 { return .wait }
            // Without a readable baseline there is no reliable duplicate-safe verification.
            guard let baseline = observation.text else { return fail("R74-READ") }
            before = baseline
            phase = .verifying; phaseTicks = 0
            return .paste
        case .verifying:
            // Never re-paste blindly. A delayed paste must not duplicate an answer.
            guard observation.composer else { return fail("R74-WINDOW") }
            if ReplyInsertionPolicy.confirmsInsertion(note: note, before: before, after: observation.text) {
                confirmations += 1
                if confirmations >= 3 && phaseTicks >= 5 {
                    phase = .done
                    return .complete
                }
            } else {
                confirmations = 0
            }
            return phaseTicks > 25 ? fail("R74-VERIFY") : .wait
        case .done:
            return .wait
        }
    }
    private mutating func fail(_ code: String) -> Action {
        phase = .done
        return .fail(code)
    }
}
