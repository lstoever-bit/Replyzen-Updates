import AppKit
import ApplicationServices

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

    func hideDelayedTooltip() {
        tooltipWorkItem?.cancel()
        tooltipWorkItem = nil
        tooltipPanel?.orderOut(nil)
        tooltipPanel = nil
    }

    private func showDelayedTooltip() {
        guard let window else { return }
        hideDelayedTooltip()

        let label = NSTextField(labelWithString: delayedTooltipText)
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

final class OutlookToolbarButtonController: NSObject {
    private let outlook: OutlookAccessibility
    private let panel: NSPanel
    private let newButton: DelayedTooltipButton
    private let replyButton: DelayedTooltipButton
    private let replyAllButton: DelayedTooltipButton
    private let forwardButton: DelayedTooltipButton
    private let cancelButton: DelayedTooltipButton
    private let calendarButton: DelayedTooltipButton
    private let paymentButton: DelayedTooltipButton
    private var timer: Timer?
    private var isSuppressed = false

    var newAction: (() -> Void)?
    var replyAction: (() -> Void)?
    var replyAllAction: (() -> Void)?
    var forwardAction: (() -> Void)?
    var cancelAction: (() -> Void)?
    var calendarAction: (() -> Void)?
    var paymentAction: (() -> Void)?

    init(outlook: OutlookAccessibility) {
        self.outlook = outlook

        let size = NSSize(width: 302, height: 34)
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

        func makeButton(symbol: String, x: CGFloat, tooltip: String) -> DelayedTooltipButton {
            let button = DelayedTooltipButton(
                frame: NSRect(x: x, y: 3, width: 38, height: 28),
                tooltipText: tooltip
            )
            button.title = ""
            button.bezelStyle = .rounded
            button.isBordered = false
            button.setButtonType(.momentaryPushIn)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.setAccessibilityLabel(tooltip)
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

        newButton = makeButton(symbol: "square.and.pencil", x: 6, tooltip: "New")
        replyButton = makeButton(symbol: "arrowshape.turn.up.left", x: 46, tooltip: "Reply")
        replyAllButton = makeButton(symbol: "arrowshape.turn.up.left.2", x: 86, tooltip: "Reply All")
        forwardButton = makeButton(symbol: "arrowshape.turn.up.right", x: 126, tooltip: "Forward")
        cancelButton = makeButton(symbol: "xmark.circle", x: 178, tooltip: "Cancel")
        calendarButton = makeButton(symbol: "calendar.badge.plus", x: 218, tooltip: "Calendar")
        paymentButton = makeButton(symbol: "banknote", x: 258, tooltip: "Payment")

        effect.addSubview(newButton)
        effect.addSubview(replyButton)
        effect.addSubview(replyAllButton)
        effect.addSubview(forwardButton)
        effect.addSubview(makePipe(x: 166))
        effect.addSubview(cancelButton)
        effect.addSubview(calendarButton)
        effect.addSubview(paymentButton)

        panel.contentView = effect
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true

        super.init()

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

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(timer!, forMode: .common)
        update()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        hideAllTooltips()
        panel.orderOut(nil)
    }

    func setSuppressed(_ suppressed: Bool) {
        isSuppressed = suppressed
        if suppressed {
            hideAllTooltips()
            panel.orderOut(nil)
        } else {
            update()
        }
    }

    @objc private func newClicked() { newAction?() }
    @objc private func replyClicked() { replyAction?() }
    @objc private func replyAllClicked() { replyAllAction?() }
    @objc private func forwardClicked() { forwardAction?() }
    @objc private func cancelClicked() { cancelAction?() }
    @objc private func calendarClicked() { calendarAction?() }
    @objc private func paymentClicked() { paymentAction?() }

    private func hideAllTooltips() {
        [newButton, replyButton, replyAllButton, forwardButton, cancelButton, calendarButton, paymentButton]
            .forEach { $0.hideDelayedTooltip() }
    }

    private func update() {
        guard !isSuppressed,
              outlook.isTrusted(),
              let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.microsoft.Outlook" }),
              running.isActive,
              let frame = outlook.focusedWindowFrameInAppKitCoordinates() else {
            hideAllTooltips()
            panel.orderOut(nil)
            return
        }

        let size = panel.frame.size
        let x = frame.maxX - size.width - 122
        let y = frame.maxY - size.height - 38
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }
}
