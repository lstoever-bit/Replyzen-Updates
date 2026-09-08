import AppKit

private final class DelayedTooltipButton: NSButton {
    private let delayedTooltipText: String
    private var tracking: NSTrackingArea?
    private var tooltipWorkItem: DispatchWorkItem?
    private var tooltipPanel: NSPanel?

    init(frame frameRect: NSRect, tooltipText: String) {
        self.delayedTooltipText = tooltipText
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        tooltipWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.showDelayedTooltip() }
        tooltipWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: item)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hideDelayedTooltip()
    }

    override func mouseDown(with event: NSEvent) {
        hideDelayedTooltip()
        super.mouseDown(with: event)
    }

    func refreshLocalization() {
        hideDelayedTooltip()
        setAccessibilityLabel(L10n.render(delayedTooltipText))
    }

    func hideDelayedTooltip() {
        tooltipWorkItem?.cancel()
        tooltipWorkItem = nil
        tooltipPanel?.orderOut(nil)
        tooltipPanel = nil
    }

    private func showDelayedTooltip() {
        guard let window else { return }
        hideDelayedTooltip()
        let label = NSTextField(labelWithString: L10n.render(delayedTooltipText))
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.sizeToFit()
        let width = max(58, label.frame.width + 18)
        let height: CGFloat = 26
        let tooltip = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        tooltip.isOpaque = false
        tooltip.backgroundColor = .clear
        tooltip.hasShadow = true
        tooltip.level = .popUpMenu
        tooltip.ignoresMouseEvents = true
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        label.frame = NSRect(x: 9, y: 5, width: width - 18, height: 16)
        background.addSubview(label)
        tooltip.contentView = background
        let buttonRectOnScreen = window.convertToScreen(convert(bounds, to: nil))
        tooltip.setFrameOrigin(NSPoint(x: buttonRectOnScreen.midX - width / 2, y: buttonRectOnScreen.minY - height - 7))
        tooltip.orderFrontRegardless()
        tooltipPanel = tooltip
    }
}

private final class OutlookToolbarDragHandle: NSView {
    var onDragBegan: (() -> Void)?
    var onDragChanged: (() -> Void)?
    var onDragEnded: (() -> Void)?
    private var dragStart: (pointer: NSPoint, origin: NSPoint)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The decorative grip image must not swallow mouse events.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStart = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin)
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let window else { return }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(NSPoint(x: start.origin.x + pointer.x - start.pointer.x,
                                      y: start.origin.y + pointer.y - start.pointer.y))
        onDragChanged?()
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        // Commit the actual release coordinates, not the start of a native drag.
        mouseDragged(with: event)
        cancelDrag()
    }

    func cancelDrag() {
        guard dragStart != nil else { return }
        dragStart = nil
        onDragEnded?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }
}

final class OutlookToolbarButtonController: NSObject {
    private static let offsetXKey = "Replyzen.OutlookToolbar.OffsetX.v1"
    private static let offsetYKey = "Replyzen.OutlookToolbar.OffsetY.v1"
    private let outlook: OutlookAccessibility
    private let defaults: UserDefaults
    private let outlookIsFrontmost: () -> Bool
    private let panel: NSPanel
    private let newButton: DelayedTooltipButton
    private let replyButton: DelayedTooltipButton
    private let replyAllButton: DelayedTooltipButton
    private let forwardButton: DelayedTooltipButton
    private let cancelButton: DelayedTooltipButton
    private let calendarButton: DelayedTooltipButton
    private let dragHandle: OutlookToolbarDragHandle
    private var timer: Timer?
    private var isSuppressed = false
    private var isStarted = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isDragging = false
    private var toolbarOffset = NSPoint.zero
    private var lastOutlookFrame: NSRect?
    private var dragOutlookFrame: NSRect?

    var newAction: (() -> Void)?
    var replyAction: (() -> Void)?
    var replyAllAction: (() -> Void)?
    var forwardAction: (() -> Void)?
    var cancelAction: (() -> Void)?
    var calendarAction: (() -> Void)?

    init(outlook: OutlookAccessibility, defaults: UserDefaults = .standard,
         outlookIsFrontmost: @escaping () -> Bool = {
             NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.microsoft.Outlook"
         }) {
        self.outlook = outlook
        self.defaults = defaults
        self.outlookIsFrontmost = outlookIsFrontmost
        dragHandle = OutlookToolbarDragHandle(frame: NSRect(x: 0, y: 0, width: 20, height: 34))
        dragHandle.identifier = NSUserInterfaceItemIdentifier("replyzen.outlookActions.dragHandle")
        let size = NSSize(width: 282, height: 34)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("replyzen.outlookActions")
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
        effect.layer?.masksToBounds = true
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let overlayTint = isDark ? NSColor(calibratedWhite: 0.16, alpha: 0.78) : NSColor(calibratedWhite: 0.84, alpha: 0.82)
        effect.layer?.backgroundColor = overlayTint.cgColor
        effect.layer?.borderWidth = 0.6
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        let grip = NSImageView(frame: NSRect(x: 4, y: 9, width: 12, height: 16))
        grip.image = NSImage(systemSymbolName: "circle.grid.2x3.fill", accessibilityDescription: nil)
        grip.imageScaling = .scaleProportionallyDown
        grip.contentTintColor = .tertiaryLabelColor
        dragHandle.addSubview(grip)
        effect.addSubview(dragHandle)

        func makeButton(symbol: String, x: CGFloat, tooltip: String) -> DelayedTooltipButton {
            let button = DelayedTooltipButton(frame: NSRect(x: x, y: 3, width: 38, height: 28), tooltipText: tooltip)
            button.title = ""
            button.bezelStyle = .rounded
            button.isBordered = false
            button.setButtonType(.momentaryPushIn)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L10n.render(tooltip))
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.setAccessibilityLabel(L10n.render(tooltip))
            return button
        }
        func makePipe(x: CGFloat) -> NSTextField {
            let pipe = NSTextField(labelWithString: "|")
            pipe.frame = NSRect(x: x, y: 7, width: 12, height: 20)
            pipe.alignment = .center
            pipe.font = .systemFont(ofSize: 13, weight: .regular)
            pipe.textColor = .secondaryLabelColor.withAlphaComponent(0.65)
            return pipe
        }
        newButton = makeButton(symbol: "square.and.pencil", x: 26, tooltip: L10n.source("New"))
        replyButton = makeButton(symbol: "arrowshape.turn.up.left", x: 66, tooltip: L10n.source("Reply"))
        replyAllButton = makeButton(symbol: "arrowshape.turn.up.left.2", x: 106, tooltip: L10n.source("Reply All"))
        forwardButton = makeButton(symbol: "arrowshape.turn.up.right", x: 146, tooltip: L10n.source("Forward"))
        cancelButton = makeButton(symbol: "xmark.circle", x: 198, tooltip: L10n.source("Cancel"))
        calendarButton = makeButton(symbol: "calendar.badge.plus", x: 238, tooltip: L10n.source("Calendar"))
        [newButton, replyButton, replyAllButton, forwardButton, cancelButton, calendarButton].forEach { effect.addSubview($0) }
        effect.addSubview(makePipe(x: 186))
        panel.contentView = effect
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        super.init()
        let x = defaults.double(forKey: Self.offsetXKey)
        let y = defaults.double(forKey: Self.offsetYKey)
        toolbarOffset = x.isFinite && y.isFinite ? NSPoint(x: x, y: y) : .zero
        dragHandle.onDragBegan = { [weak self] in self?.beginToolbarDrag() }
        dragHandle.onDragChanged = { [weak self] in self?.trackToolbarDrag() }
        dragHandle.onDragEnded = { [weak self] in self?.endToolbarDrag() }
        newButton.target = self
        newButton.action = #selector(newClicked)
        replyButton.target = self
        replyButton.action = #selector(replyClicked)
        replyAllButton.target = self
        replyAllButton.action = #selector(replyAllClicked)
        forwardButton.target = self
        forwardButton.action = #selector(forwardClicked)
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        calendarButton.target = self
        calendarButton.action = #selector(calendarClicked)
    }

    func start() {
        guard !isStarted else { refreshPollingState(); return }
        isStarted = true
        let center = NSWorkspace.shared.notificationCenter
        let notifications: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification
        ]
        workspaceObservers = notifications.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshPollingState() }
        }
        refreshPollingState()
    }

    func stop() {
        isStarted = false
        removeWorkspaceObservers()
        pausePolling()
        hideOverlay()
    }

    deinit {
        timer?.invalidate()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        panel.orderOut(nil)
    }

    func setSuppressed(_ suppressed: Bool) {
        isSuppressed = suppressed
        refreshPollingState()
    }

    private var shouldPoll: Bool { isStarted && !isSuppressed && outlookIsFrontmost() }

    private func refreshPollingState() {
        guard shouldPoll else { pausePolling(); hideOverlay(); return }
        if timer == nil {
            let newTimer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in self?.update() }
            newTimer.tolerance = 0.07
            timer = newTimer
            RunLoop.main.add(newTimer, forMode: .common)
        }
        update()
    }

    private func pausePolling() { timer?.invalidate(); timer = nil }

    private func removeWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    private func hideOverlay() {
        // Interrupted gestures save their last actual location as well.
        dragHandle.cancelDrag()
        hideAllTooltips()
        if panel.isVisible { panel.orderOut(nil) }
    }

    @objc private func newClicked() { newAction?() }
    @objc private func replyClicked() { replyAction?() }
    @objc private func replyAllClicked() { replyAllAction?() }
    @objc private func forwardClicked() { forwardAction?() }
    @objc private func cancelClicked() { cancelAction?() }
    @objc private func calendarClicked() { calendarAction?() }

    private func beginToolbarDrag() {
        hideAllTooltips()
        dragOutlookFrame = lastOutlookFrame ?? outlook.focusedWindowFrameInAppKitCoordinates()
        isDragging = true
    }

    private func trackToolbarDrag() {
        guard let outlookFrame = dragOutlookFrame else { return }
        let anchor = defaultOrigin(for: outlookFrame)
        toolbarOffset = NSPoint(x: panel.frame.minX - anchor.x, y: panel.frame.minY - anchor.y)
    }

    private func endToolbarDrag() {
        guard isDragging else { return }
        defer { isDragging = false; dragOutlookFrame = nil }
        guard let outlookFrame = dragOutlookFrame else { return }
        let origin = clampedOrigin(panel.frame.origin, relativeTo: outlookFrame)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        trackToolbarDrag()
        defaults.set(Double(toolbarOffset.x), forKey: Self.offsetXKey)
        defaults.set(Double(toolbarOffset.y), forKey: Self.offsetYKey)
    }

    private func defaultOrigin(for outlookFrame: NSRect) -> NSPoint {
        let size = panel.frame.size
        return NSPoint(x: outlookFrame.maxX - size.width - 122, y: outlookFrame.maxY - size.height - 38)
    }

    private func clampedOrigin(_ origin: NSPoint, relativeTo outlookFrame: NSRect) -> NSPoint {
        let center = NSPoint(x: outlookFrame.midX, y: outlookFrame.midY)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) ?? NSScreen.main else { return origin }
        let visible = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        return NSPoint(x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - panel.frame.width)),
                       y: min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - panel.frame.height)))
    }

    func refreshLocalization() {
        [newButton, replyButton, replyAllButton, forwardButton, cancelButton, calendarButton].forEach { $0.refreshLocalization() }
    }

    private func hideAllTooltips() {
        [newButton, replyButton, replyAllButton, forwardButton, cancelButton, calendarButton].forEach { $0.hideDelayedTooltip() }
    }

    private func update() {
        // The timer must never reposition the palette during a mouse gesture.
        if isDragging { return }
        guard shouldPoll else { pausePolling(); hideOverlay(); return }
        guard outlook.isTrusted(), let frame = outlook.focusedWindowFrameInAppKitCoordinates() else { hideOverlay(); return }
        lastOutlookFrame = frame
        let anchor = defaultOrigin(for: frame)
        let desired = NSPoint(x: anchor.x + toolbarOffset.x, y: anchor.y + toolbarOffset.y)
        let origin = clampedOrigin(desired, relativeTo: frame)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        // Automatic following/clamping must never overwrite the user's offset.
    }
}
