import AppKit
import SwiftUI
import Combine

final class FloatingPanelController: NSWindowController, NSWindowDelegate {
    private let panel: NSPanel
    private let state: AppState
    private var cancellables = Set<AnyCancellable>()
    private var resizeWorkItem: DispatchWorkItem?
    private var layoutRevision = 0
    private var workspaceActivationObserver: NSObjectProtocol?
    private var wantsVisibleInOutlookContext = false
    var onClose: (() -> Void)?

    init(state: AppState, defaults: UserDefaults = .standard) {
        self.state = state
        // Delete the old preference, but never read or write a workspace position.
        defaults.removeObject(forKey: "Replyzen.FloatingPanel.Frame.v1")
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        let host = NSHostingController(rootView: OverlayView(state: state))
        panel.contentViewController = host
        panel.title = ReplyZenBrand.displayName
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.isRestorable = false
        _ = panel.setFrameAutosaveName("")
        panel.minSize = NSSize(width: 680, height: 560)
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
        cancelScheduledResize()
        wantsVisibleInOutlookContext = true
        // Every explicit opening starts centered, independent of any old frame.
        resizeForCurrentState(animated: false, centered: true)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        stabilizeVisibleContent()
    }

    /// SwiftUI contains an AppKit-backed rich-text editor. On a freshly shown
    /// accessory panel AppKit can finish the native subview layout one run-loop
    /// later than SwiftUI. Run a few cheap, bounded layout/display passes while
    /// the window is visible so the complete workspace is correct immediately.
    private func stabilizeVisibleContent() {
        for delay: TimeInterval in [0.0, 0.035, 0.11] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.panel.isVisible else { return }
                let roots = [self.panel.contentViewController?.view, self.panel.contentView].compactMap { $0 }
                for root in roots {
                    root.needsLayout = true
                    root.layoutSubtreeIfNeeded()
                    root.needsDisplay = true
                    root.displayIfNeeded()
                }
                self.panel.invalidateShadow()
            }
        }
    }

    func selectInstructionTextSoon() {
        let delays: [TimeInterval] = [0.05, 0.16, 0.34]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.selectInstructionTextIfPossible()
            }
        }
    }

    private func selectInstructionTextIfPossible() {
        guard panel.isVisible, state.stage == .instruction, state.outputMode == .reply,
              let root = panel.contentView else { return }
        let expected = state.instruction
        guard !expected.isEmpty else { return }
        if let textView = findInstructionTextView(in: root, expectedText: expected) {
            panel.makeKey()
            panel.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }

    private func findInstructionTextView(in view: NSView, expectedText: String) -> NSTextView? {
        if let textView = view as? NSTextView, textView.isEditable,
           textView.string == expectedText { return textView }
        for child in view.subviews {
            if let found = findInstructionTextView(in: child, expectedText: expectedText) { return found }
        }
        return nil
    }

    func hide() {
        cancelScheduledResize()
        wantsVisibleInOutlookContext = false
        panel.orderOut(nil)
    }

    private func hideForExternalApp() {
        cancelScheduledResize()
        panel.orderOut(nil)
    }

    private func restoreForOutlookIfNeeded() {
        guard wantsVisibleInOutlookContext, !panel.isVisible else { return }
        // A temporarily hidden workspace is a new appearance too: always center.
        show(activate: false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        onClose?()
        return false
    }

    // Shared by real workspace notifications and lifecycle regression tests.
    func handleWorkspaceActivation(bundleIdentifier: String) {
        if bundleIdentifier == "com.microsoft.Outlook" {
            restoreForOutlookIfNeeded()
        } else if bundleIdentifier != Bundle.main.bundleIdentifier, panel.isVisible {
            hideForExternalApp()
        }
    }

    private func observeWorkspaceContext() {
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.handleWorkspaceActivation(bundleIdentifier: app.bundleIdentifier ?? "")
        }
    }

    deinit {
        resizeWorkItem?.cancel()
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
    }

    private func observeLayoutState() {
        state.$stage.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.scheduleAdaptiveResize() }.store(in: &cancellables)
        state.$outputMode.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.scheduleAdaptiveResize() }.store(in: &cancellables)
        state.$googleNeedsOAuthCredentials.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.scheduleAdaptiveResize() }.store(in: &cancellables)
        state.$googleConnectedEmail.map { $0.isEmpty }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.scheduleAdaptiveResize() }.store(in: &cancellables)
        state.$calendarWarning.map { $0.isEmpty }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.scheduleAdaptiveResize() }.store(in: &cancellables)
    }

    private func cancelScheduledResize() {
        layoutRevision += 1
        resizeWorkItem?.cancel()
        resizeWorkItem = nil
    }

    private func scheduleAdaptiveResize() {
        cancelScheduledResize()
        guard panel.isVisible else { return }
        let revision = layoutRevision
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.layoutRevision == revision, self.panel.isVisible else { return }
            self.resizeWorkItem = nil
            self.resizeForCurrentState(animated: true)
        }
        resizeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: item)
    }

    private func resizeForCurrentState(animated: Bool, centered: Bool = false) {
        // Only the live, currently visible frame may anchor an in-place resize.
        // There is no position cache or restoration path for a hidden window.
        let referenceFrame: NSRect? = !centered && panel.isVisible ? panel.frame : nil
        let preferredScreen = referenceFrame.flatMap { screen(containing: $0) }
        guard let targetScreen = preferredScreen ?? screenUnderMouse() ?? NSScreen.main else { return }
        let visible = targetScreen.visibleFrame.insetBy(dx: 10, dy: 10)
        let preferred = preferredContentSize()
        let chromeWidth = max(0, panel.frame.width - panel.contentLayoutRect.width)
        let chromeHeight = max(0, panel.frame.height - panel.contentLayoutRect.height)
        let contentSize = NSSize(
            width: min(preferred.width, max(560, visible.width - chromeWidth)),
            height: min(preferred.height, max(380, visible.height - chromeHeight))
        )
        var targetFrame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        if let referenceFrame, screen(containing: referenceFrame) != nil {
            targetFrame.origin = NSPoint(x: referenceFrame.minX, y: referenceFrame.maxY - targetFrame.height)
        } else {
            targetFrame.origin = NSPoint(x: visible.midX - targetFrame.width / 2, y: visible.midY - targetFrame.height / 2)
        }
        if targetFrame.minX < visible.minX { targetFrame.origin.x = visible.minX }
        if targetFrame.maxX > visible.maxX { targetFrame.origin.x = visible.maxX - targetFrame.width }
        if targetFrame.minY < visible.minY { targetFrame.origin.y = visible.minY }
        if targetFrame.maxY > visible.maxY { targetFrame.origin.y = visible.maxY - targetFrame.height }
        panel.setFrame(targetFrame, display: true, animate: animated && panel.isVisible)
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) })
    }

    private func preferredContentSize() -> NSSize {
        switch state.stage {
        case .startup:
            return NSSize(width: 650, height: 430)
        case .instruction:
            switch state.outputMode {
            case .reply, .newMail, .forward: return NSSize(width: 900, height: 740)
            case .calendar, .payment: return NSSize(width: 840, height: 640)
            }
        case .calendarPreview:
            let extraOAuthHeight = state.googleNeedsOAuthCredentials ? 130.0 : 0.0
            let warningHeight = state.calendarWarning.isEmpty ? 0.0 : 50.0
            return NSSize(width: 880, height: 760 + extraOAuthHeight + warningHeight)
        case .paymentPreview: return NSSize(width: 840, height: 690)
        case .preview: return NSSize(width: 900, height: 740)
        case .apiKey, .needsAccessibility, .error: return NSSize(width: 720, height: 520)
        case .generating, .updating, .inserting: return NSSize(width: 680, height: 400)
        case .success, .idle: return NSSize(width: 650, height: 430)
        }
    }

    private func screenUnderMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}
