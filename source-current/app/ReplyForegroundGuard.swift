import Foundation

/// Distinguish ReplyZen briefly becoming active from the user choosing another app.
/// No mail contents or application identifiers are retained by this policy.
struct ReplyForegroundGuard {
    enum Owner: Equatable { case outlook, replyzen, unavailable, other }
    enum Decision: Equatable { case ready, wait, handoff; case abort(String) }
    private var lossStarted: TimeInterval?
    private var stableSince: TimeInterval?
    private var lastRequest: TimeInterval?
    private var requests = 0
    private var failure: String?

    mutating func next(owner: Owner, ownInteractiveWindow: Bool, now: TimeInterval) -> Decision {
        if let failure { return .abort(failure) }
        // Never activate Outlook over a different app deliberately chosen by the user.
        if owner == .other { return fail("R75-APPFOCUS-EXTERNAL") }
        if owner == .replyzen && ownInteractiveWindow { return fail("R75-APPFOCUS-OWNUI") }
        if owner == .outlook && lossStarted == nil { return .ready }
        if lossStarted == nil { lossStarted = now }
        if let lossStarted, now - lossStarted >= 2.0 {
            return fail(owner == .unavailable ? "R75-APPFOCUS-UNKNOWN" : "R75-APPFOCUS-TIMEOUT")
        }
        if owner == .outlook {
            if stableSince == nil { stableSince = now }
            if let stableSince, now - stableSince >= 0.2 {
                lossStarted = nil
                self.stableSince = nil
                return .ready
            }
            return .wait
        }
        stableSince = nil
        // Missing foreground data is not permission to force any app to the front.
        guard owner == .replyzen else { return .wait }
        if lastRequest == nil || now - lastRequest! >= 0.4 {
            guard requests < 2 else { return fail("R75-APPFOCUS-LIMIT") }
            requests += 1
            lastRequest = now
            return .handoff
        }
        return .wait
    }

    private mutating func fail(_ code: String) -> Decision {
        failure = code
        return .abort(code)
    }
}
