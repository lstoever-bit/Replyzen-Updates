import AppKit
import SwiftUI

final class FloatingPanelController: NSWindowController, NSWindowDelegate {
    private let panel: NSPanel
    var onClose: (() -> Void)?

    init(state: AppState, commands: CommandStore) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        let host = NSHostingController(rootView: OverlayView(state: state, commands: commands))
        panel.contentViewController = host

        panel.title = "Replyzen"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 700, height: 620)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true

        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(activate: Bool = true) {
        if let screen = screenUnderMouse() ?? NSScreen.main {
            let visible = screen.visibleFrame
            var frame = panel.frame

            if frame.width > visible.width - 40 {
                frame.size.width = max(700, visible.width - 28)
            }
            if frame.height > visible.height - 40 {
                frame.size.height = max(620, visible.height - 28)
            }

            frame.origin = NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.midY - frame.height / 2
            )
            panel.setFrame(frame, display: false)
        }

        panel.orderFrontRegardless()

        if activate {
            panel.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose?()
        return false
    }

    private func screenUnderMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}
