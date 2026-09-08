import AppKit

/// Dedicated grab area for ReplyZen's full-size-content floating panel.
/// The view intentionally contains no controls; AppKit handles the actual window drag.
final class ReplyZenWindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }
}
