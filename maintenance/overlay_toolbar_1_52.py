#!/usr/bin/env python3
"""One-time checked migration for ReplyZen 1.52 window positioning."""
from pathlib import Path
import plistlib
import sys

root = Path(sys.argv[1])
app = root / "app"
info_path = app / "Info.plist"
info = plistlib.loads(info_path.read_bytes())

if info["CFBundleShortVersionString"] == "1.52.0":
    print("ReplyZen 1.52 migration already applied")
    raise SystemExit(0)
if info["CFBundleShortVersionString"] != "1.51.0":
    raise SystemExit("Unexpected source version; refusing to modify newer work")


def once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise RuntimeError("Expected one source marker: " + old[:120])
    return text.replace(old, new, 1)


# The large ReplyZen workspace remains movable while open, but its location is
# intentionally session-only. Closing it resets the next open to screen center.
floating_path = app / "FloatingPanelController.swift"
floating = floating_path.read_text(encoding="utf-8")
floating = once(
    floating,
    '    private static let savedFrameKey = "Replyzen.FloatingPanel.Frame.v1"\n\n',
    ""
)
floating = once(
    floating,
    "    private var isApplyingProgrammaticFrame = false\n",
    ""
)
floating = once(
    floating,
    """    func hide() {
        wantsVisibleInOutlookContext = false
        panel.orderOut(nil)
    }
""",
    """    func hide() {
        wantsVisibleInOutlookContext = false
        hasPositionedPanel = false
        panel.orderOut(nil)
    }
"""
)
floating = once(
    floating,
    """    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose?()
        return false
    }
""",
    """    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hasPositionedPanel = false
        onClose?()
        return false
    }
"""
)
start = floating.index("    func windowDidMove(_ notification: Notification) {")
end = floating.index("    private func observeWorkspaceContext() {", start)
floating = floating[:start] + floating[end:]
floating = once(
    floating,
    """        let saved = hasPositionedPanel ? nil : savedPanelFrame()
        let referenceFrame: NSRect? = saved ?? (hasPositionedPanel ? panel.frame : nil)
        let preferredScreen = referenceFrame.flatMap { screen(containing: $0) }
""",
    """        let referenceFrame: NSRect? = hasPositionedPanel ? panel.frame : nil
        let preferredScreen = referenceFrame.flatMap { screen(containing: $0) }
"""
)
floating = once(
    floating,
    """        hasPositionedPanel = true
        isApplyingProgrammaticFrame = true
        panel.setFrame(targetFrame, display: true, animate: animated && panel.isVisible)
        let releaseDelay: TimeInterval = animated && panel.isVisible ? 0.30 : 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseDelay) { [weak self] in
            self?.isApplyingProgrammaticFrame = false
        }
""",
    """        hasPositionedPanel = true
        panel.setFrame(targetFrame, display: true, animate: animated && panel.isVisible)
"""
)
if "savedPanelFrame" in floating or "NSStringFromRect" in floating or "NSRectFromString" in floating:
    raise RuntimeError("Large-window persistence was not fully removed")
floating_path.write_text(floating, encoding="utf-8")


# The compact Outlook action overlay gets its own drag handle. Its saved offset
# is relative to Outlook's normal anchor, so it keeps following the Outlook
# window instead of becoming a detached absolute-position palette.
toolbar_path = app / "OutlookToolbarButtonController.swift"
toolbar = toolbar_path.read_text(encoding="utf-8")

drag_class = r'''
private final class OutlookToolbarDragHandle: NSView {
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        onDragBegan?()
        window.performDrag(with: event)
        onDragEnded?()
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

'''
toolbar = once(
    toolbar,
    "final class OutlookToolbarButtonController: NSObject {\n",
    drag_class + "final class OutlookToolbarButtonController: NSObject {\n"
)
toolbar = once(
    toolbar,
    "final class OutlookToolbarButtonController: NSObject {\n    private let outlook: OutlookAccessibility\n",
    """final class OutlookToolbarButtonController: NSObject {
    private static let offsetXKey = "Replyzen.OutlookToolbar.OffsetX.v1"
    private static let offsetYKey = "Replyzen.OutlookToolbar.OffsetY.v1"

    private let outlook: OutlookAccessibility
"""
)
toolbar = once(
    toolbar,
    "    private let paymentButton: DelayedTooltipButton\n",
    """    private let paymentButton: DelayedTooltipButton
    private let dragHandle: OutlookToolbarDragHandle
"""
)
toolbar = once(
    toolbar,
    "    private var workspaceObservers: [NSObjectProtocol] = []\n",
    """    private var workspaceObservers: [NSObjectProtocol] = []
    private var isDragging = false
    private var toolbarOffset = NSPoint.zero
    private var lastOutlookFrame: NSRect?
"""
)
toolbar = once(
    toolbar,
    """        self.outlook = outlook

        let size = NSSize(width: 302, height: 34)
""",
    """        self.outlook = outlook
        dragHandle = OutlookToolbarDragHandle(frame: NSRect(x: 0, y: 0, width: 20, height: 34))

        let size = NSSize(width: 322, height: 34)
"""
)
toolbar = once(
    toolbar,
    """        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor

        func makeButton(symbol: String, x: CGFloat, tooltip: String) -> DelayedTooltipButton {
""",
    """        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor

        let grip = NSImageView(frame: NSRect(x: 4, y: 9, width: 12, height: 16))
        grip.image = NSImage(systemSymbolName: "circle.grid.2x3.fill", accessibilityDescription: nil)
        grip.imageScaling = .scaleProportionallyDown
        grip.contentTintColor = .tertiaryLabelColor
        dragHandle.addSubview(grip)
        effect.addSubview(dragHandle)

        func makeButton(symbol: String, x: CGFloat, tooltip: String) -> DelayedTooltipButton {
"""
)
for old, new in [
    ('x: 6, tooltip:', 'x: 26, tooltip:'),
    ('x: 46, tooltip:', 'x: 66, tooltip:'),
    ('x: 86, tooltip:', 'x: 106, tooltip:'),
    ('x: 126, tooltip:', 'x: 146, tooltip:'),
    ('makePipe(x: 166)', 'makePipe(x: 186)'),
    ('x: 178, tooltip:', 'x: 198, tooltip:'),
    ('x: 218, tooltip:', 'x: 238, tooltip:'),
    ('x: 258, tooltip:', 'x: 278, tooltip:'),
]:
    toolbar = once(toolbar, old, new)
toolbar = once(
    toolbar,
    """        panel.level = .floating
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
""",
    """        panel.level = .floating
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
"""
)
toolbar = once(
    toolbar,
    """        super.init()

        newButton.target = self
""",
    """        super.init()

        let defaults = UserDefaults.standard
        toolbarOffset = NSPoint(
            x: defaults.double(forKey: Self.offsetXKey),
            y: defaults.double(forKey: Self.offsetYKey)
        )
        dragHandle.onDragBegan = { [weak self] in self?.beginToolbarDrag() }
        dragHandle.onDragEnded = { [weak self] in self?.endToolbarDrag() }

        newButton.target = self
"""
)

methods = r'''    private func beginToolbarDrag() {
        hideAllTooltips()
        isDragging = true
    }

    private func endToolbarDrag() {
        isDragging = false
        guard let outlookFrame = lastOutlookFrame ?? outlook.focusedWindowFrameInAppKitCoordinates() else { return }
        let origin = clampedOrigin(panel.frame.origin, relativeTo: outlookFrame)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        let anchor = defaultOrigin(for: outlookFrame)
        toolbarOffset = NSPoint(x: origin.x - anchor.x, y: origin.y - anchor.y)
        let defaults = UserDefaults.standard
        defaults.set(Double(toolbarOffset.x), forKey: Self.offsetXKey)
        defaults.set(Double(toolbarOffset.y), forKey: Self.offsetYKey)
    }

    private func defaultOrigin(for outlookFrame: NSRect) -> NSPoint {
        let size = panel.frame.size
        return NSPoint(
            x: outlookFrame.maxX - size.width - 122,
            y: outlookFrame.maxY - size.height - 38
        )
    }

    private func clampedOrigin(_ origin: NSPoint, relativeTo outlookFrame: NSRect) -> NSPoint {
        let center = NSPoint(x: outlookFrame.midX, y: outlookFrame.midY)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) ?? NSScreen.main else {
            return origin
        }
        let visible = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        var result = origin
        if result.x < visible.minX { result.x = visible.minX }
        if result.x + panel.frame.width > visible.maxX { result.x = visible.maxX - panel.frame.width }
        if result.y < visible.minY { result.y = visible.minY }
        if result.y + panel.frame.height > visible.maxY { result.y = visible.maxY - panel.frame.height }
        return result
    }

'''
toolbar = once(toolbar, "    func refreshLocalization() {\n", methods + "    func refreshLocalization() {\n")
toolbar = once(
    toolbar,
    """        let size = panel.frame.size
        let origin = NSPoint(x: frame.maxX - size.width - 122,
                             y: frame.maxY - size.height - 38)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
""",
    """        lastOutlookFrame = frame
        if isDragging {
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }

        let anchor = defaultOrigin(for: frame)
        let desired = NSPoint(x: anchor.x + toolbarOffset.x, y: anchor.y + toolbarOffset.y)
        let origin = clampedOrigin(desired, relativeTo: frame)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
"""
)
if "panel.isMovable = false" in toolbar:
    raise RuntimeError("Toolbar remained non-movable")
toolbar_path.write_text(toolbar, encoding="utf-8")

info["CFBundleShortVersionString"] = "1.52.0"
info["CFBundleVersion"] = "53"
info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
print("Migrated ReplyZen to 1.52.0 / build 53")
