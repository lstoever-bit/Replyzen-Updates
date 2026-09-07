import AppKit

final class HotKeyMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    var action: (() -> Void)?

    func start() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.control), flags.contains(.option),
                  event.charactersIgnoringModifiers?.lowercased() == "r" else { return }
            DispatchQueue.main.async { self?.action?() }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.control), flags.contains(.option),
               event.charactersIgnoringModifiers?.lowercased() == "r" {
                DispatchQueue.main.async { [weak self] in self?.action?() }
                return nil
            }
            return event
        }
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
