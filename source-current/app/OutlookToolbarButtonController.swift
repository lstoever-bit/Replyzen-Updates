import AppKit
import ApplicationServices

final class OutlookToolbarButtonController: NSObject {
    private let outlook: OutlookAccessibility
    private let panel: NSPanel
    private let button: NSButton
    private var timer: Timer?
    private var isSuppressed = false

    var action: (() -> Void)?

    init(outlook: OutlookAccessibility) {
        self.outlook = outlook

        let size = NSSize(width: 112, height: 34)
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

        button = NSButton(frame: effect.bounds.insetBy(dx: 4, dy: 3))
        button.title = "Replyzen"
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12.5, weight: .semibold)
        button.alignment = .center
        button.target = nil
        button.action = nil
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.toolTip = "Replyzen"

        if let logoURL = Bundle.main.url(forResource: "ReplyzenLogo", withExtension: "png"),
           let logo = NSImage(contentsOf: logoURL) {
            logo.size = NSSize(width: 18, height: 18)
            button.image = logo
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
        }

        effect.addSubview(button)

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

        button.target = self
        button.action = #selector(buttonClicked)
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.update()
        }
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
        if suppressed {
            panel.orderOut(nil)
        } else {
            update()
        }
    }

    @objc private func buttonClicked() {
        action?()
    }

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
