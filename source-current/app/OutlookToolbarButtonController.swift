import AppKit
import ApplicationServices

final class OutlookToolbarButtonController: NSObject {
    private let outlook: OutlookAccessibility
    private let panel: NSPanel
    private let newButton: NSButton
    private let replyButton: NSButton
    private let replyAllButton: NSButton
    private let forwardButton: NSButton
    private let cancelButton: NSButton
    private let calendarButton: NSButton
    private var timer: Timer?
    private var isSuppressed = false

    var newAction: (() -> Void)?
    var replyAction: (() -> Void)?
    var replyAllAction: (() -> Void)?
    var forwardAction: (() -> Void)?
    var cancelAction: (() -> Void)?
    var calendarAction: (() -> Void)?

    init(outlook: OutlookAccessibility) {
        self.outlook = outlook

        let size = NSSize(width: 540, height: 34)
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
        // Keep the native translucent Outlook feel, but separate the Replyzen bar
        // very slightly from Outlook's default toolbar gray.
        effect.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.22).cgColor

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

        newButton = makeButton(title: "New", symbol: "square.and.pencil", x: 4, width: 68, help: "Neue Mail mit Replyzen")
        replyButton = makeButton(title: "Reply", symbol: "arrowshape.turn.up.left", x: 76, width: 74, help: "Nur dem Absender antworten")
        replyAllButton = makeButton(title: "Reply All", symbol: "arrowshape.turn.up.left.2", x: 154, width: 94, help: "Allen Empfängern antworten")
        forwardButton = makeButton(title: "Forward", symbol: "arrowshape.turn.up.right", x: 252, width: 88, help: "Aktuelle Mail mit Replyzen weiterleiten")
        cancelButton = makeButton(title: "Cancel", symbol: "xmark.circle", x: 344, width: 96, help: "Freundliche kurze Absage direkt als Antwort einsetzen")
        calendarButton = makeButton(title: "Termin", symbol: "calendar.badge.plus", x: 444, width: 92, help: "Termin aus der aktuellen Mail mit Replyzen erstellen")

        effect.addSubview(newButton)
        effect.addSubview(replyButton)
        effect.addSubview(replyAllButton)
        effect.addSubview(forwardButton)
        effect.addSubview(cancelButton)
        effect.addSubview(calendarButton)

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
    @objc private func replyAllClicked() { replyAllAction?() }
    @objc private func forwardClicked() { forwardAction?() }
    @objc private func cancelClicked() { cancelAction?() }
    @objc private func calendarClicked() { calendarAction?() }

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
        let y = frame.maxY - size.height - 38
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }
}
