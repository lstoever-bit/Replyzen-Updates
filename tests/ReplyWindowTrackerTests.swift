import Foundation

@main struct ReplyWindowTrackerTests {
    static var checks = 0
    static func check(_ test: @autoclosure () -> Bool, _ name: String) {
        precondition(test(), name)
        checks += 1
    }
    typealias Tracker = ReplyWindowTracker<Int, Int>
    static func tracker() -> Tracker { Tracker(sameWindow: ==, sameEditor: ==) }

    // The production window policy feeds the production insertion state, as the
    // AX adapter does. Values stand for AX identities; this is not a live Outlook test.
    struct Harness {
        var windows = Tracker(sameWindow: ==, sameEditor: ==)
        var insertion = ReplyInsertionState(note: "Hello", nativeOpenAccepted: true)
        var pastes: [Int] = []
        var completions = 0
        var errors: [String] = []
        var actions: [ReplyInsertionState.Action] = []
        mutating func tick(window: Int?, editor: Int?, source: Bool = false,
                           existed: Bool = false, send: Bool = true, modal: Bool = false,
                           focused: Bool = true, caret: Bool = true, text: String? = "Original") {
            var observation = ReplyInsertionState.Observation()
            let decision = windows.observe(window: window, editor: editor, isSource: source,
                existedBefore: existed, hasSend: send, modal: modal)
            switch decision {
            case .wait:
                observation.windowPending = true
            case .openingSource:
                break
            case .reject(let code):
                errors.append(code)
                observation.targetChanged = true
            case .ready(let rebound):
                observation.composer = true
                observation.editor = true
                observation.editorRebound = rebound
                observation.focused = focused
                observation.caretAtStart = caret
                observation.text = text
            }
            let action = insertion.next(observation)
            actions.append(action)
            if case .paste = action {
                guard let window, let editor, windows.lockForPaste(window: window, editor: editor) else {
                    errors.append("lease-failed"); return
                }
                pastes.append(window)
            }
            if action == .complete { completions += 1 }
            if case .fail(let code) = action { errors.append(code) }
        }
    }

    static func main() {
        // Reproduce the exact pre-1.74 binding rule from observe(): Send alone
        // selected the source, and a detached composer became targetChanged.
        var oldTarget: Int? = nil
        let source = 1, detached = 2
        let sourceHasSend = true
        if oldTarget == nil && sourceHasSend { oldTarget = source }
        check(oldTarget != detached, "1.73 prematurely bound source -> R73-WINDOW")

        var t = tracker()
        check(t.observe(window: 1, editor: nil, isSource: true, existedBefore: true,
                        hasSend: true, modal: false) == .wait, "Send alone must not bind source")
        check(t.readyWindow == nil, "no target without a body")
        check(!t.lockForPaste(window: 1, editor: 10), "cannot write to partial source")
        for _ in 0..<2 {
            check(t.observe(window: 2, editor: 20, isSource: false, existedBefore: false,
                            hasSend: true, modal: false) == .wait, "wait for stable detached body")
        }
        check(t.observe(window: 2, editor: 20, isSource: false, existedBefore: false,
                        hasSend: true, modal: false) == .ready(rebound: true), "bind complete detached draft")
        check(t.readyWindow == 2, "detached target, not source")
        check(!t.lockForPaste(window: 99, editor: 20), "write boundary rejects raced window")
        check(!t.lockForPaste(window: 2, editor: 99), "write boundary rejects wrong body")
        check(t.lockForPaste(window: 2, editor: 20), "write lease succeeds once")
        check(!t.lockForPaste(window: 2, editor: 20), "cannot paste twice")
        check(t.observe(window: 3, editor: 30, isSource: false, existedBefore: false,
                        hasSend: true, modal: false) == .reject("R74-WINDOW-AFTERPASTE"), "no retarget after paste")

        var opening = Harness()
        opening.tick(window: 1, editor: nil, source: true, existed: true)
        opening.tick(window: nil, editor: nil, send: false)
        // Previously open unrelated window may become active during activation.
        opening.tick(window: 99, editor: 990, existed: true)
        check(opening.pastes.isEmpty && opening.errors.isEmpty, "no paste/false abort on transient opening windows")
        for _ in 0..<6 { opening.tick(window: 2, editor: 20) }
        check(opening.pastes == [2], "opening -> detached inserts once")
        for _ in 0..<6 { opening.tick(window: 2, editor: 20, text: "Hello\n\nOriginal") }
        check(opening.completions == 1 && opening.errors.isEmpty, "detached read-back succeeds")

        var inline = Harness()
        for _ in 0..<6 { inline.tick(window: 1, editor: 10, source: true, existed: true) }
        check(inline.pastes == [1], "inline replies still work")
        for _ in 0..<6 { inline.tick(window: 1, editor: 10, source: true, existed: true, text: "Hello\n\nOriginal") }
        check(inline.completions == 1 && inline.errors.isEmpty, "inline read-back succeeds")

        var handoff = Harness()
        // Source editor was ready and received focus, but no text has been pasted.
        for _ in 0..<4 { handoff.tick(window: 1, editor: 10, source: true, existed: true) }
        check(handoff.pastes.isEmpty, "no early paste before handoff")
        handoff.tick(window: nil, editor: nil, send: false)
        for _ in 0..<6 { handoff.tick(window: 2, editor: 20) }
        check(handoff.pastes == [2] && handoff.errors.isEmpty, "inline -> detached restarts focus/caret, not failure")
        check(handoff.actions.filter { $0 == .position }.count == 2, "caret positioned again in new draft")
        for _ in 0..<6 { handoff.tick(window: 2, editor: 20, text: "Hello\n\nOriginal") }
        check(handoff.completions == 1, "handoff completes after actual read-back")

        var redraw = Harness()
        for _ in 0..<6 { redraw.tick(window: 2, editor: 20) }
        redraw.tick(window: nil, editor: nil, send: false)
        redraw.tick(window: 2, editor: nil, send: false)
        redraw.tick(window: 2, editor: nil, modal: true)
        check(redraw.errors.isEmpty && redraw.pastes == [2], "temporary missing AX window/body does not abort or re-paste")
        for _ in 0..<6 { redraw.tick(window: 2, editor: 21, text: "Hello\n\nOriginal") }
        check(redraw.completions == 1 && redraw.errors.isEmpty, "same draft new AX editor verified without duplicate")

        var unknown = Harness()
        for _ in 0..<6 { unknown.tick(window: 2, editor: 20) }
        for _ in 0..<28 { unknown.tick(window: 2, editor: nil, send: false) }
        check(unknown.completions == 0 && unknown.pastes == [2], "missing result is never success or retry")
        check(unknown.errors.contains("R74-VERIFY"), "unreadable result times out specifically")

        var switched = Harness()
        for _ in 0..<6 { switched.tick(window: 2, editor: 20) }
        switched.tick(window: 3, editor: 30)
        check(switched.errors.contains("R74-WINDOW-AFTERPASTE"), "genuine window switch after paste still rejected")
        check(switched.pastes == [2] && switched.completions == 0, "never paste into second window")

        var ambiguous = Harness()
        for _ in 0..<3 { ambiguous.tick(window: 2, editor: 20) }
        ambiguous.tick(window: 3, editor: 30)
        check(ambiguous.errors.contains("R74-WINDOW-AMBIGUOUS"), "two different detached drafts are not guessed")
        check(ambiguous.pastes.isEmpty, "ambiguous drafts receive no text")

        var existing = Harness()
        for _ in 0..<3 { existing.tick(window: 1, editor: 10, source: true, existed: true) }
        existing.tick(window: 99, editor: 990, existed: true)
        check(existing.errors.contains("R74-WINDOW-EXISTING") && existing.pastes.isEmpty, "known unrelated draft rejected after selection")

        var noReady = Harness()
        for _ in 0..<105 { noReady.tick(window: nil, editor: nil, send: false) }
        check(noReady.errors == ["R74-TIMEOUT"] && noReady.pastes.isEmpty, "bounded wait, one failure")

        var focusLost = Harness()
        for _ in 0..<6 { focusLost.tick(window: 2, editor: 20, focused: false) }
        check(focusLost.pastes.isEmpty, "window readiness cannot bypass editor focus")
        var noText = Harness()
        for _ in 0..<8 { noText.tick(window: 2, editor: 20, text: nil) }
        check(noText.errors.contains("R74-READ") && noText.pastes.isEmpty, "window readiness cannot bypass readable baseline")

        // Stability resets for a genuinely rebuilt body before the first write.
        var rebuilt = Harness()
        for _ in 0..<4 { rebuilt.tick(window: 2, editor: 20) }
        for _ in 0..<2 { rebuilt.tick(window: 2, editor: 21) }
        check(rebuilt.pastes.isEmpty, "new editor needs its own stable observations")
        for _ in 0..<4 { rebuilt.tick(window: 2, editor: 21) }
        check(rebuilt.pastes == [2] && rebuilt.errors.isEmpty, "pre-paste body rebuild is recoverable")
        var noNative = Harness()
        noNative.insertion = ReplyInsertionState(note: "Hello", nativeOpenAccepted: false)
        for _ in 0..<9 { noNative.tick(window: 1, editor: nil, source: true, existed: true, send: false) }
        check(noNative.actions.filter { $0 == .keyboardFallback }.count == 1, "opening-source fallback remains available once")
        check(noNative.pastes.isEmpty && noNative.errors.isEmpty, "opening-source navigation is not insertion")
        for _ in 0..<6 { noNative.tick(window: 2, editor: 20) }
        check(noNative.pastes == [2], "keyboard fallback reaches new reply without another shortcut")

        var earlyAmbiguous = tracker()
        _ = earlyAmbiguous.observe(window: 2, editor: 20, isSource: false, existedBefore: false, hasSend: true, modal: false)
        check(earlyAmbiguous.observe(window: 3, editor: 30, isSource: false, existedBefore: false, hasSend: true, modal: false) == .reject("R74-WINDOW-AMBIGUOUS"), "two new complete drafts before stability are ambiguous too")

        var longHandoff = Harness()
        for _ in 0..<4 { longHandoff.tick(window: 1, editor: 10, source: true, existed: true) }
        for _ in 0..<15 { longHandoff.tick(window: nil, editor: nil, send: false) }
        for _ in 0..<6 { longHandoff.tick(window: 2, editor: 20) }
        check(longHandoff.errors.isEmpty && longHandoff.pastes == [2], "readiness waits don't expire the caret phase")
        print("PASS: \(checks) window-transition and integrated insertion checks (simulated AX identities, no live Outlook)")
    }
}
