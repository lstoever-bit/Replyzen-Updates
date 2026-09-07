import AppKit
import ApplicationServices

final class OutlookToolbarButtonController: NSObject {
    private let outlook: OutlookAccessibility
    private let panel: NSPanel
    private let newButton: NSButton
    private let replyButton: NSButton
    private let declineButton: NSButton
    private var timer: Timer?
    private var isSuppressed = false

    var newAction: (() -> Void)?
    var replyAction: (() -> Void)?
    var declineAction: (() -> Void)?

    init(outlook: OutlookAccessibility) {
        self.outlook = outlook

        let size = NSSize(width: 250, height: 34)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
        effect.layer?.masksToBounds = true

        func makeButton(title: String, symbol: String, x: CGFloat, width: CGFloat, help: String) -> NSButton {
            let button = NSButton(frame: NSRect(x: x, y: 3, width: width, height: 28))
            button.title = title
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 12.5, weight: .semibold)
            button.alignment = .center
            button.isBordered = false
            button.setButtonType(.momentaryPushIn)
            button.toolTip = help
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            return button
        }

        newButton = makeButton(title: "New", symbol: "square.and.pencil", x: 4, width: 72, help: "Neue Mail mit Replyzen")
        replyButton = makeButton(title: "Reply", symbol: "arrowshape.turn.up.left.fill", x: 84, width: 76, help: "Auf die aktuelle Mail antworten")
        declineButton = makeButton(title: "Decline", symbol: "xmark.circle", x: 168, width: 78, help: "Freundliche kurze Absage direkt als Antwort einsetzen")

        effect.addSubview(newButton)
        effect.addSubview(replyButton)
        effect.addSubview(declineButton)

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
        declineButton.target = self
        declineButton.action = #selector(declineClicked)
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
        panel.orderOut(nil)
    }

    func setSuppressed(_ suppressed: Bool) {
        isSuppressed = suppressed
        if suppressed { panel.orderOut(nil) } else { update() }
    }

    @objc private func newClicked() { newAction?() }
    @objc private func replyClicked() { replyAction?() }
    @objc private func declineClicked() { declineAction?() }

    private func update() {
        guard !isSuppressed,
              outlook.isTrusted(),
              let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.microsoft.Outlook" }),
              running.isActive,
              let frame = outlook.focusedWindowFrameInAppKitCoordinates() else {
            panel.orderOut(nil)
            return
        }

        let size = panel.frame.size
        let x = frame.maxX - size.width - 122
        let y = frame.maxY - size.height - 10
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }
}
