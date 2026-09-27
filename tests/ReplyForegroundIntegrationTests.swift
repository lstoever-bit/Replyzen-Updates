import Foundation

@main struct ReplyForegroundIntegrationTests {
    static func main() {
        // Reproduce the old state failure with the exact production state source.
        var old = ReplyInsertionState(note: "Answer", nativeOpenAccepted: true)
        var lost = ReplyInsertionState.Observation(); lost.active = false
        precondition(old.next(lost) == .fail("R74-FOCUS"))

        var state = ReplyInsertionState(note: "Answer", nativeOpenAccepted: true)
        var gate = ReplyForegroundGuard()
        var observation = ReplyInsertionState.Observation()
        observation.composer = true; observation.editor = true
        observation.focused = true; observation.caretAtStart = true
        observation.text = "Original"
        var pastes = 0, completions = 0, handoffs = 0
        func poll(_ owner: ReplyForegroundGuard.Owner, _ time: Double) {
            let decision = gate.next(owner: owner, ownInteractiveWindow: false, now: time)
            switch decision {
            case .handoff: handoffs += 1
            case .wait: break
            case .abort(let code): preconditionFailure("Unexpected abort: \(code)")
            case .ready:
                let action = state.next(observation)
                switch action {
                case .paste:
                    pastes += 1
                    observation.text = "Answer\n\nOriginal"
                case .complete: completions += 1
                case .fail(let code): preconditionFailure("Unexpected state failure: \(code)")
                default: break
                }
            }
        }
        poll(.outlook, 0) // focus
        poll(.outlook, 0.2) // caret
        poll(.replyzen, 0.4) // own hidden process interrupts before paste
        poll(.outlook, 0.6)
        poll(.outlook, 0.9)
        poll(.outlook, 1.1) // one paste
        precondition(pastes == 1 && completions == 0)
        poll(.replyzen, 1.3) // interruption after paste must not recreate state
        poll(.outlook, 1.5)
        for time in [1.8, 2.0, 2.2, 2.4, 2.6, 2.8] { poll(.outlook, time) }
        precondition(pastes == 1 && completions == 1 && handoffs == 2)
        precondition(observation.text == "Answer\n\nOriginal")
        print("PASS: old APPFOCUS failure reproduced; new pre/post-paste handoff retains one paste and one verified completion")
    }
}
