import AppKit
import SwiftUI
import Combine

final class FloatingPanelController: NSWindowController, NSWindowDelegate {
    private let panel: NSPanel
    private let state: AppState
    private var cancellables = Set<AnyCancellable>()
    private var resizeWorkItem: DispatchWorkItem?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var wantsVisibleInOutlookContext = false
    var onClose: (() -> Void)?

    init(state: AppState, commands: CommandStore) {
        self.state = state
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 700),
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
        panel.minSize = NSSize(width: 600, height: 420)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true

        super.init(window: panel)
        panel.delegate = self
        observeLayoutState()
        observeWorkspaceContext()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(activate: Bool = true) {
        wantsVisibleInOutlookContext = true
        resizeForCurrentState(animated: false)
        panel.orderFrontRegardless()

        if activate {
            panel.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func hide() {
        wantsVisibleInOutlookContext = false
        panel.orderOut(nil)
    }

    private func hideForExternalApp() {
        panel.orderOut(nil)
    }

    private func restoreForOutlookIfNeeded() {
        guard wantsVisibleInOutlookContext else { return }
        resizeForCurrentState(animated: false)
        panel.orderFrontRegardless()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose?()
        return false
    }

    private func observeWorkspaceContext() {
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

            let bundleID = app.bundleIdentifier ?? ""
            if bundleID == "com.microsoft.Outlook" {
                self.restoreForOutlookIfNeeded()
                return
            }

            // Replyzen itself is allowed to stay visible while the user types in the panel.
            if bundleID == Bundle.main.bundleIdentifier {
                return
            }

            // Any other foreground app (browser, Finder, Slack, etc.) hides the panel,
            // but remembers that it should return when Outlook becomes active again.
            if self.panel.isVisible {
                self.hideForExternalApp()
            }
        }
    }

    deinit {
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
    }

    private func observeLayoutState() {
        state.$stage
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleAdaptiveResize() }
            .store(in: &cancellables)

        state.$outputMode
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleAdaptiveResize() }
            .store(in: &cancellables)

        state.$googleNeedsOAuthCredentials
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleAdaptiveResize() }
            .store(in: &cancellables)

        state.$googleConnectedEmail
            .map { $0.isEmpty }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleAdaptiveResize() }
            .store(in: &cancellables)

        state.$calendarWarning
            .map { $0.isEmpty }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleAdaptiveResize() }
            .store(in: &cancellables)
    }

    private func scheduleAdaptiveResize() {
        resizeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.resizeForCurrentState(animated: true)
        }
        resizeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: item)
    }

    private func resizeForCurrentState(animated: Bool) {
        guard let screen = screenUnderMouse() ?? panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 10, dy: 10)
        let preferred = preferredContentSize()

        // Account for the title-bar/window chrome so the whole panel always stays on screen.
        let chromeWidth = max(0, panel.frame.width - panel.contentLayoutRect.width)
        let chromeHeight = max(0, panel.frame.height - panel.contentLayoutRect.height)
        let maxContentWidth = max(560, visible.width - chromeWidth)
        let maxContentHeight = max(380, visible.height - chromeHeight)

        let contentSize = NSSize(
            width: min(preferred.width, maxContentWidth),
            height: min(preferred.height, maxContentHeight)
        )

        var targetFrame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        targetFrame.origin = NSPoint(
            x: visible.midX - targetFrame.width / 2,
            y: visible.midY - targetFrame.height / 2
        )

        // Final safety clamp for unusual menu-bar/dock layouts.
        if targetFrame.minX < visible.minX { targetFrame.origin.x = visible.minX }
        if targetFrame.maxX > visible.maxX { targetFrame.origin.x = visible.maxX - targetFrame.width }
        if targetFrame.minY < visible.minY { targetFrame.origin.y = visible.minY }
        if targetFrame.maxY > visible.maxY { targetFrame.origin.y = visible.maxY - targetFrame.height }

        panel.setFrame(targetFrame, display: true, animate: animated && panel.isVisible)
    }

    private func preferredContentSize() -> NSSize {
        switch state.stage {
        case .startup:
            return NSSize(width: 650, height: 430)
        case .instruction:
            switch state.outputMode {
            case .reply, .newMail:
                return NSSize(width: 840, height: 760)
            case .calendar:
                return NSSize(width: 840, height: 640)
            }
        case .calendarPreview:
            let extraOAuthHeight = state.googleNeedsOAuthCredentials ? 130.0 : 0.0
            let warningHeight = state.calendarWarning.isEmpty ? 0.0 : 50.0
            return NSSize(width: 880, height: 760 + extraOAuthHeight + warningHeight)
        case .preview:
            return NSSize(width: 780, height: 560)
        case .apiKey, .needsAccessibility, .error:
            return NSSize(width: 720, height: 520)
        case .generating, .updating, .inserting:
            return NSSize(width: 680, height: 400)
        case .success, .idle:
            return NSSize(width: 650, height: 430)
        }
    }

    private func screenUnderMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}
