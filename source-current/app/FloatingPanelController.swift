import AppKit
import SwiftUI

final class FloatingPanelController: NSWindowController, NSWindowDelegate {
    private let panel: NSPanel
    var onClose: (() -> Void)?

    init(state: AppState, commands: CommandStore) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
            styleMask: [.titled, .closable, .fullSizeContentView],
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
            let size = panel.frame.size
            let origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            )
            panel.setFrameOrigin(origin)
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
