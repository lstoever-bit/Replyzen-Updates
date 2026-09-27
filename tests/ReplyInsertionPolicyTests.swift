import Foundation

@main struct ReplyInsertionPolicyTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label); checks += 1
        }
        for label in ["Send", "Senden", "Nachricht senden", "Enviar", "Send (Command+Return)"] {
            check(ReplyInsertionPolicy.isSendControl(label), "real Send: \(label)")
        }
        for label in ["Send/Receive", "Senden/Empfangen", "Send later", "Undo send", "Sender", "Send feedback", "Receive", "Send receive all folders"] {
            check(!ReplyInsertionPolicy.isSendControl(label), "not a composer: \(label)")
        }
        check(ReplyInsertionPolicy.bodyScore(named: true, editable: false, wasReadPane: true, area: 900_000) == nil, "read pane rejected even if named body")
        check(ReplyInsertionPolicy.bodyScore(named: true, editable: true, wasReadPane: true, area: 30_000) != nil, "inline editor reusing original node accepted only with editability")
        check(ReplyInsertionPolicy.bodyScore(named: true, editable: false, wasReadPane: false, area: 30_000) != nil, "named Legacy body does not need AXValue write support")
        check(ReplyInsertionPolicy.bodyScore(named: false, editable: false, wasReadPane: false, area: 900_000) == nil, "large web area alone is insufficient")
        let note = "Hallo M\u{00FC}ller,\n\nvielen Dank! \u{1F44D}", original = "Original message\nQuoted history"
        let combined = note + "\n\n" + original
        check(ReplyInsertionPolicy.confirmsInsertion(note: note, before: original, after: combined), "unicode note verified")
        check(!ReplyInsertionPolicy.confirmsInsertion(note: note, before: combined, after: combined), "preexisting quote is not a successful insertion")
        check(!ReplyInsertionPolicy.confirmsInsertion(note: note, before: original, after: nil), "unreadable body is not success")
        check(!ReplyInsertionPolicy.confirmsInsertion(note: note, before: original, after: note), "body replacement loses original and fails")
        check(ReplyInsertionPolicy.normalized("a\u{00A0}b\r\n\u{200B}c") == "a b c", "HTML whitespace normalized")

        func prepared(_ expected: String, before: String) -> ReplyInsertionState {
            var state = ReplyInsertionState(note: expected, nativeOpenAccepted: true)
            var obs = ReplyInsertionState.Observation()
            obs.composer = true; obs.editor = true; obs.text = before
            precondition(state.next(obs) == .focus)
            obs.focused = true
            precondition(state.next(obs) == .position)
            obs.caretAtStart = true
            precondition(state.next(obs) == .wait)
            precondition(state.next(obs) == .paste)
            return state
        }
        var good = prepared(note, before: original)
        var obs = ReplyInsertionState.Observation()
        obs.composer = true; obs.editor = true; obs.focused = true; obs.text = combined
        var actions = (0..<8).map { _ in good.next(obs) }
        check(actions.filter { $0 == .complete }.count == 1, "verified success exactly once")
        check(!actions.contains(.paste), "verification never re-pastes")

        var dropped = prepared(note, before: original)
        obs.text = original
        actions = (0..<30).map { _ in dropped.next(obs) }
        check(actions.contains(.fail("R71-VERIFY")) && !actions.contains(.complete), "dropped paste is a real failure")
        check(!actions.contains(.paste), "late paste cannot cause duplicate retry")

        var rebuilt = prepared(note, before: original)
        obs.text = combined
        _ = rebuilt.next(obs); _ = rebuilt.next(obs)
        obs.text = original
        actions = (0..<30).map { _ in rebuilt.next(obs) }
        check(!actions.contains(.complete), "text overwritten by Outlook never confirms")

        var opening = ReplyInsertionState(note: note, nativeOpenAccepted: false)
        let noComposer = ReplyInsertionState.Observation()
        actions = (0..<55).map { _ in opening.next(noComposer) }
        check(actions.filter { $0 == .keyboardFallback }.count == 1, "one opening shortcut at most")
        check(!actions.contains(.paste), "read pane never receives paste")

        var slowNative = ReplyInsertionState(note: note, nativeOpenAccepted: true)
        actions = (0..<20).map { _ in slowNative.next(noComposer) }
        check(!actions.contains(.keyboardFallback), "slow acknowledged native open cannot create duplicate draft")

        var inactive = ReplyInsertionState(note: note, nativeOpenAccepted: true)
        var away = ReplyInsertionState.Observation(); away.active = false
        check(inactive.next(away) == .fail("R71-FOCUS"), "switch to another app aborts")
        var wrongWindow = ReplyInsertionState(note: note, nativeOpenAccepted: true)
        away.active = true; away.targetChanged = true
        check(wrongWindow.next(away) == .fail("R71-WINDOW"), "different draft is never modified")

        var falseFocus = ReplyInsertionState(note: note, nativeOpenAccepted: true)
        obs.composer = true; obs.editor = true; obs.focused = false; obs.text = original
        actions = (0..<25).map { _ in falseFocus.next(obs) }
        check(!actions.contains(.paste) && actions.contains(.fail("R71-FOCUS")), "AX accepting a request does not prove real focus")

        var unreadable = ReplyInsertionState(note: note, nativeOpenAccepted: true)
        obs.focused = true; obs.caretAtStart = true; obs.text = nil
        actions = (0..<5).map { _ in unreadable.next(obs) }
        check(!actions.contains(.paste) && actions.contains(.fail("R71-READ")), "unknown baseline never risks duplicate insertion")
        print("PASS: \(checks) Reply insertion checks (state machine and selector policy; no live Outlook)")
    }
}
