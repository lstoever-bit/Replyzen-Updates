import Foundation

/// A Send control is not a window binding. Outlook may expose one in the source
/// before it finishes opening a detached reply. Bind only a stable Send + body
/// pair; freeze that binding at the first paste, not at the first Send label.
struct ReplyWindowTracker<Window, Editor> {
    enum Decision: Equatable {
        case wait, openingSource
        case ready(rebound: Bool)
        case reject(String)
    }

    private let sameWindow: (Window, Window) -> Bool
    private let sameEditor: (Editor, Editor) -> Bool
    private var candidateWindow: Window?
    private var candidateEditor: Editor?
    private var stablePasses = 0
    private var detachedWindow: Window?
    private(set) var readyWindow: Window?
    private(set) var readyEditor: Editor?
    private var lockedWindow: Window?
    private var latestWasReady = false

    init(sameWindow: @escaping (Window, Window) -> Bool,
         sameEditor: @escaping (Editor, Editor) -> Bool) {
        self.sameWindow = sameWindow
        self.sameEditor = sameEditor
    }

    mutating func observe(window: Window?, editor: Editor?, isSource: Bool,
                          existedBefore: Bool, hasSend: Bool, modal: Bool) -> Decision {
        latestWasReady = false
        guard let window else {
            stablePasses = 0
            return .wait
        }
        if let lockedWindow {
            guard sameWindow(lockedWindow, window) else {
                return .reject("R74-WINDOW-AFTERPASTE")
            }
            // Missing AX controls during a redraw are not a different window.
            // Wait for read-back in the SAME draft; never paste a second time.
            guard !modal, hasSend, let editor else { return .wait }
            readyWindow = window
            readyEditor = editor
            latestWasReady = true
            return .ready(rebound: false)
        }
        guard !modal else { stablePasses = 0; return .wait }
        if existedBefore && !isSource {
            stablePasses = 0
            // Activation can pass through a previously open Outlook window.
            // Never focus/paste there; once a draft was selected, abort a switch.
            return readyWindow == nil ? .wait : .reject("R74-WINDOW-EXISTING")
        }
        // Once detached, don't fall back to an editor in the original read pane.
        if detachedWindow != nil && isSource { stablePasses = 0; return .wait }
        guard hasSend, let editor else {
            stablePasses = 0
            return isSource && readyWindow == nil && !hasSend ? .openingSource : .wait
        }
        if !isSource, let detachedWindow, !sameWindow(detachedWindow, window) {
            return .reject("R74-WINDOW-AMBIGUOUS")
        }
        if !isSource && detachedWindow == nil { detachedWindow = window }
        if let candidateWindow, let candidateEditor,
           sameWindow(candidateWindow, window), sameEditor(candidateEditor, editor) {
            stablePasses += 1
        } else {
            candidateWindow = window
            candidateEditor = editor
            stablePasses = 1
        }
        guard stablePasses >= 3 else { return .wait }
        let changedWindow = readyWindow.map { !sameWindow($0, window) } ?? true
        let changedEditor = readyEditor.map { !sameEditor($0, editor) } ?? true
        readyWindow = window
        readyEditor = editor
        if !isSource { detachedWindow = window }
        latestWasReady = true
        return .ready(rebound: changedWindow || changedEditor)
    }

    /// Called after the final focus/window check, immediately before the paste.
    /// A not-yet-ready or different window cannot acquire this write lease.
    mutating func lockForPaste(window: Window, editor: Editor) -> Bool {
        guard lockedWindow == nil, latestWasReady,
              let readyWindow, let readyEditor,
              sameWindow(readyWindow, window), sameEditor(readyEditor, editor) else { return false }
        lockedWindow = window
        return true
    }
}
