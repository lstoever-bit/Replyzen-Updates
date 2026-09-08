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

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        tooltipWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.showDelayedTooltip()
        }
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
        let tooltip = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
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

        let buttonRectInWindow = convert(bounds, to: nil)
        let buttonRectOnScreen = window.convertToScreen(buttonRectInWindow)
        let x = buttonRectOnScreen.midX - width / 2
        let y = buttonRectOnScreen.minY - height - 7
        tooltip.setFrameOrigin(NSPoint(x: x, y: y))
        tooltip.orderFrontRegardless()
        tooltipPanel = tooltip
    }
}


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

final class OutlookToolbarButtonController: NSObject {
    private static let offsetXKey = "Replyzen.OutlookToolbar.OffsetX.v1"
    private static let offsetYKey = "Replyzen.OutlookToolbar.OffsetY.v1"

    private let outlook: OutlookAccessibility
    private let panel: NSPanel
    private let newButton: DelayedTooltipButton
    private let replyButton: DelayedTooltipButton
    private let replyAllButton: DelayedTooltipButton
    private let forwardButton: DelayedTooltipButton
    private let cancelButton: DelayedTooltipButton
    private let calendarButton: DelayedTooltipButton
    private let paymentButton: DelayedTooltipButton
    private let dragHandle: OutlookToolbarDragHandle
    private var timer: Timer?
    private var isSuppressed = false
    private var isStarted = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isDragging = false
    private var toolbarOffset = NSPoint.zero
    private var lastOutlookFrame: NSRect?

    var newAction: (() -> Void)?
    var replyAction: (() -> Void)?
    var replyAllAction: (() -> Void)?
    var forwardAction: (() -> Void)?
    var cancelAction: (() -> Void)?
    var calendarAction: (() -> Void)?
    var paymentAction: (() -> Void)?

    init(outlook: OutlookAccessibility) {
        self.outlook = outlook
        dragHandle = OutlookToolbarDragHandle(frame: NSRect(x: 0, y: 0, width: 20, height: 34))

        let size = NSSize(width: 322, height: 34)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
        effect.layer?.masksToBounds = true
        // Deliberately a little stronger than Outlook's toolbar gray so Replyzen
        // reads as one compact control while still feeling native on macOS.
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let overlayTint = isDark
            ? NSColor(calibratedWhite: 0.16, alpha: 0.78)
            : NSColor(calibratedWhite: 0.84, alpha: 0.82)
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
            let button = DelayedTooltipButton(
                frame: NSRect(x: x, y: 3, width: 38, height: 28),
                tooltipText: tooltip
            )
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
        paymentButton = makeButton(symbol: "banknote", x: 278, tooltip: L10n.source("Payment"))

        effect.addSubview(newButton)
        effect.addSubview(replyButton)
        effect.addSubview(replyAllButton)
        effect.addSubview(forwardButton)
        effect.addSubview(makePipe(x: 186))
        effect.addSubview(cancelButton)
        effect.addSubview(calendarButton)
        effect.addSubview(paymentButton)

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

        let defaults = UserDefaults.standard
        toolbarOffset = NSPoint(
            x: defaults.double(forKey: Self.offsetXKey),
            y: defaults.double(forKey: Self.offsetYKey)
        )
        dragHandle.onDragBegan = { [weak self] in self?.beginToolbarDrag() }
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
        paymentButton.target = self
        paymentButton.action = #selector(paymentClicked)
    }

    // Observe activation changes; poll geometry only while the toolbar can be used.
    func start() {
        guard !isStarted else {
            refreshPollingState()
            return
        }
        isStarted = true
        let center = NSWorkspace.shared.notificationCenter
        let notifications: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didWakeNotification
        ]
        workspaceObservers = notifications.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshPollingState()
            }
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
    }

    func setSuppressed(_ suppressed: Bool) {
        isSuppressed = suppressed
        refreshPollingState()
    }

    private var shouldPoll: Bool {
        isStarted && !isSuppressed &&
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.microsoft.Outlook"
    }

    private func refreshPollingState() {
        guard shouldPoll else {
            pausePolling()
            hideOverlay()
            return
        }
        if timer == nil {
            let newTimer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
                self?.update()
            }
            newTimer.tolerance = 0.07
            timer = newTimer
            RunLoop.main.add(newTimer, forMode: .common)
        }
        update()
    }

    private func pausePolling() {
        timer?.invalidate()
        timer = nil
    }

    private func removeWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    private func hideOverlay() {
        hideAllTooltips()
        if panel.isVisible { panel.orderOut(nil) }
    }

    @objc private func newClicked() { newAction?() }
    @objc private func replyClicked() { replyAction?() }
    @objc private func replyAllClicked() { replyAllAction?() }
    @objc private func forwardClicked() { forwardAction?() }
    @objc private func cancelClicked() { cancelAction?() }
    @objc private func calendarClicked() { calendarAction?() }
    @objc private func paymentClicked() { paymentAction?() }

    private func beginToolbarDrag() {
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

    func refreshLocalization() {
        [newButton, replyButton, replyAllButton, forwardButton, cancelButton, calendarButton, paymentButton]
            .forEach { $0.refreshLocalization() }
    }

    private func hideAllTooltips() {
        [newButton, replyButton, replyAllButton, forwardButton, cancelButton, calendarButton, paymentButton]
            .forEach { $0.hideDelayedTooltip() }
    }

    private func update() {
        guard shouldPoll else {
            pausePolling()
            hideOverlay()
            return
        }
        guard outlook.isTrusted(),
              let frame = outlook.focusedWindowFrameInAppKitCoordinates() else {
            hideOverlay()
            return
        }

        lastOutlookFrame = frame
        if isDragging {
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }

        let anchor = defaultOrigin(for: frame)
        let desired = NSPoint(x: anchor.x + toolbarOffset.x, y: anchor.y + toolbarOffset.y)
        let origin = clampedOrigin(desired, relativeTo: frame)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}
