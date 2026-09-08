import AppKit

/// Installs a real draggable strip above SwiftUI's full-size content.
/// The left side stays free for the standard macOS window controls.
enum ReplyZenDragInstaller {
    private static let identifier = NSUserInterfaceItemIdentifier("replyzen.windowDragZone")
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                attachIfNeeded(to: window)
            })
        }
        DispatchQueue.main.async {
            NSApp.windows.forEach { attachIfNeeded(to: $0) }
        }
    }

    private static func attachIfNeeded(to window: NSWindow) {
        guard window.title == ReplyZenBrand.displayName,
              let content = window.contentView,
              content.viewWithIdentifier(identifier) == nil else { return }

        let dragZone = ReplyZenWindowDragView(frame: .zero)
        dragZone.identifier = identifier
        dragZone.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(dragZone, positioned: .above, relativeTo: nil)

        NSLayoutConstraint.activate([
            dragZone.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 74),
            dragZone.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            dragZone.topAnchor.constraint(equalTo: content.topAnchor),
            dragZone.heightAnchor.constraint(equalToConstant: 26)
        ])
    }
}
