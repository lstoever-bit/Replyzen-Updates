import Foundation

/// Bounded activation and keyboard-focus decisions shared with the Reply adapter.
enum ReplyRecoveryRules {
    enum Activation: Equatable { case ready, request, wait, abort }
    static func activation(outlookActive: Bool, replyzenActive: Bool,
                           frontmostKnown: Bool, attempt: Int) -> Activation {
        if outlookActive { return .ready }
        if attempt >= 20 { return .abort }
        // Never steal focus back after the user switches to another application.
        if frontmostKnown && !replyzenActive { return .abort }
        return replyzenActive ? .request : .wait
    }

    enum FocusStep: Equatable { case accessibility, press, subjectTab, click }
    static func focusStep(attempt: Int) -> FocusStep {
        switch attempt {
        case ...1: return .accessibility
        case 2: return .press
        case 3: return .subjectTab
        default: return .click
        }
    }

    static func hasFocus(active: Bool, sameWindow: Bool, reportsEditor: Bool,
                         editorMarkedFocused: Bool, reportsOtherField: Bool) -> Bool {
        guard active, sameWindow, !reportsOtherField else { return false }
        // A window/container report alone never permits pasting.
        return reportsEditor || editorMarkedFocused
    }
}
