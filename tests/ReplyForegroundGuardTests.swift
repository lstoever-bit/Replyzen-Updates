import Foundation

@main struct ReplyForegroundGuardTests {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ description: String) {
            precondition(condition(), description); count += 1
        }
        var normal = ReplyForegroundGuard()
        check(normal.next(owner: .outlook, ownInteractiveWindow: false, now: 0) == .ready, "normal path has no extra wait")
        check(normal.next(owner: .outlook, ownInteractiveWindow: false, now: 20) == .ready, "normal session does not time out")
        check(normal.next(owner: .replyzen, ownInteractiveWindow: false, now: 21) == .handoff, "recover own hidden app, not immediate APPFOCUS error")
        check(normal.next(owner: .replyzen, ownInteractiveWindow: false, now: 21.1) == .wait, "allow activation to arrive")
        check(normal.next(owner: .outlook, ownInteractiveWindow: false, now: 21.2) == .wait, "await stable foreground")
        check(normal.next(owner: .outlook, ownInteractiveWindow: false, now: 21.5) == .ready, "same operation resumes after handoff")
        check(normal.next(owner: .replyzen, ownInteractiveWindow: false, now: 22) == .handoff, "second own activation can recover")
        check(normal.next(owner: .outlook, ownInteractiveWindow: false, now: 22.1) == .wait, "second recovery waits")
        check(normal.next(owner: .outlook, ownInteractiveWindow: false, now: 22.4) == .ready, "second recovery completes")
        check(normal.next(owner: .replyzen, ownInteractiveWindow: false, now: 23) == .abort("R75-APPFOCUS-LIMIT"), "at most two activation requests per operation")
        check(normal.next(owner: .outlook, ownInteractiveWindow: false, now: 24) == .abort("R75-APPFOCUS-LIMIT"), "failure is terminal")
        var external = ReplyForegroundGuard()
        check(external.next(owner: .other, ownInteractiveWindow: false, now: 0) == .abort("R75-APPFOCUS-EXTERNAL"), "user switching to another app aborts")
        check(external.next(owner: .replyzen, ownInteractiveWindow: false, now: 1) == .abort("R75-APPFOCUS-EXTERNAL"), "do not revive an aborted operation")
        var ownUI = ReplyForegroundGuard()
        check(ownUI.next(owner: .replyzen, ownInteractiveWindow: true, now: 0) == .abort("R75-APPFOCUS-OWNUI"), "do not steal from a visible ReplyZen settings window")
        var unknown = ReplyForegroundGuard()
        check(unknown.next(owner: .unavailable, ownInteractiveWindow: false, now: 0) == .wait, "nil frontmost is transient, never handoff")
        check(unknown.next(owner: .unavailable, ownInteractiveWindow: false, now: 1.9) == .wait, "bounded grace period")
        check(unknown.next(owner: .unavailable, ownInteractiveWindow: false, now: 2) == .abort("R75-APPFOCUS-UNKNOWN"), "unknown cannot wait forever")
        var transient = ReplyForegroundGuard()
        _ = transient.next(owner: .unavailable, ownInteractiveWindow: false, now: 0)
        check(transient.next(owner: .outlook, ownInteractiveWindow: false, now: 0.1) == .wait, "return from nil stabilizes")
        check(transient.next(owner: .outlook, ownInteractiveWindow: false, now: 0.4) == .ready, "nil to Outlook resumes without activation")
        check(transient.next(owner: .other, ownInteractiveWindow: false, now: 0.5) == .abort("R75-APPFOCUS-EXTERNAL"), "external switch after recovery remains protected")
        var duringRecovery = ReplyForegroundGuard()
        _ = duringRecovery.next(owner: .replyzen, ownInteractiveWindow: false, now: 0)
        check(duringRecovery.next(owner: .other, ownInteractiveWindow: false, now: 0.1) == .abort("R75-APPFOCUS-EXTERNAL"), "external app during pending handoff cancels")
        var deadline = ReplyForegroundGuard()
        _ = deadline.next(owner: .unavailable, ownInteractiveWindow: false, now: 0)
        check(deadline.next(owner: .outlook, ownInteractiveWindow: false, now: 2.1) == .abort("R75-APPFOCUS-TIMEOUT"), "deadline is not reset by unstable foreground")
        print("PASS: \(count) foreground-owner recovery checks (simulated ownership, no live Outlook)")
    }
}
