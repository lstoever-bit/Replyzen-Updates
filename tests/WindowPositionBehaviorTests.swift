import AppKit
import Foundation

@main
struct WindowPositionBehaviorTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "ReplyZen.WindowPositionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        checkWorkspace(defaults)
        checkToolbar(defaults, suite: suite)
        print("PASS: production window controllers, real AppKit windows and mouse-event handlers")
    }

    @MainActor private static func drain(_ seconds: TimeInterval = 0.18) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }
    private static func equal(_ actual: NSPoint, _ expected: NSPoint, _ message: String) {
        expect(abs(actual.x - expected.x) < 1.1 && abs(actual.y - expected.y) < 1.1,
               "\(message): got \(actual), expected \(expected)")
    }
    private static func shifted(_ point: NSPoint, _ dx: CGFloat, _ dy: CGFloat) -> NSPoint {
        NSPoint(x: point.x + dx, y: point.y + dy)
    }
    @MainActor private static func expectCentered(_ window: NSWindow, _ message: String) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let visible = screen.visibleFrame.insetBy(dx: 10, dy: 10)
        equal(NSPoint(x: window.frame.midX, y: window.frame.midY),
              NSPoint(x: visible.midX, y: visible.midY), message)
    }

    @MainActor private static func checkWorkspace(_ defaults: UserDefaults) {
        let legacyKey = "Replyzen.FloatingPanel.Frame.v1"
        defaults.set("{{13, 29}, {720, 520}}", forKey: legacyKey)
        let state = AppState()
        let controller = FloatingPanelController(state: state, defaults: defaults)
        let window = controller.window!
        controller.show(activate: false)
        drain()
        expectCentered(window, "first opening")
        expect(defaults.object(forKey: legacyKey) == nil, "legacy position was not removed")
        expect(!window.isRestorable && window.frameAutosaveName.isEmpty, "AppKit restoration is still enabled")
        expect(window.isMovable, "temporary dragging disabled")

        let temporary = shifted(window.frame.origin, 27, -19)
        window.setFrameOrigin(temporary)
        drain()
        equal(window.frame.origin, temporary, "temporary movement while visible")
        controller.handleWorkspaceActivation(bundleIdentifier: "com.microsoft.Outlook")
        equal(window.frame.origin, temporary, "visible window should not jump on focus change")

        // Reproduce the old race: a delayed resize runs after closing.
        state.stage = .generating
        controller.hide()
        drain(0.4)
        expect(!window.isVisible, "hidden workspace reopened itself")
        state.stage = .error
        drain()
        controller.show(activate: false)
        drain()
        expectCentered(window, "reopen after queued and hidden state changes")

        window.setFrameOrigin(shifted(window.frame.origin, 37, -21))
        controller.onClose = { state.stage = .idle }
        window.performClose(nil)
        drain()
        expect(!window.isVisible, "close button did not hide workspace")
        controller.show(activate: false)
        drain()
        expectCentered(window, "close button then reopen")

        window.setFrameOrigin(shifted(window.frame.origin, 45, -15))
        controller.handleWorkspaceActivation(bundleIdentifier: "com.example.other-app")
        expect(!window.isVisible, "external app did not hide workspace")
        state.stage = .error
        drain()
        controller.handleWorkspaceActivation(bundleIdentifier: "com.microsoft.Outlook")
        drain()
        expectCentered(window, "restore after another app")

        window.setFrameOrigin(shifted(window.frame.origin, 23, -17))
        controller.show(activate: false)
        drain()
        expectCentered(window, "explicit opening always centers")
        controller.hide()
        defaults.set("{{500, 500}, {720, 520}}", forKey: legacyKey)
        let recreated = FloatingPanelController(state: AppState(), defaults: defaults)
        recreated.show(activate: false)
        drain()
        expectCentered(recreated.window!, "new controller ignores prior position")
        expect(defaults.object(forKey: legacyKey) == nil, "legacy preference survived recreation")
        recreated.hide()
        print("PASS: workspace temporary movement, close/reopen, queued resize race, app-switch restore, recreation and legacy cleanup")
    }

    @MainActor private static func visibleToolbar() -> NSWindow {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "replyzen.outlookActions" && $0.isVisible }) else {
            fatalError("No visible production toolbar")
        }
        return window
    }
    @MainActor private static func event(_ type: NSEvent.EventType, at screenPoint: NSPoint, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: screenPoint),
                          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                          clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }
    private static func offset(_ defaults: UserDefaults) -> NSPoint {
        NSPoint(x: defaults.double(forKey: "Replyzen.OutlookToolbar.OffsetX.v1"),
                y: defaults.double(forKey: "Replyzen.OutlookToolbar.OffsetY.v1"))
    }

    @MainActor private static func checkToolbar(_ defaults: UserDefaults, suite: String) {
        let outlook = OutlookAccessibility()
        let originalFrame = NSScreen.main!.visibleFrame
        outlook.frame = originalFrame
        var frontmost = true
        let toolbar = OutlookToolbarButtonController(outlook: outlook, defaults: defaults, outlookIsFrontmost: { frontmost })
        toolbar.start()
        let panel = visibleToolbar()
        let root = panel.contentView!
        let handle = root.subviews.first { $0.identifier?.rawValue == "replyzen.outlookActions.dragHandle" }!
        expect(root.hitTest(NSPoint(x: 10, y: 17)) === handle, "grip image intercepts dragging")
        let origin = panel.frame.origin
        let pointer = shifted(origin, 10, 17)
        handle.mouseDown(with: event(.leftMouseDown, at: pointer, window: panel))
        handle.mouseDragged(with: event(.leftMouseDragged, at: shifted(pointer, -50, -80), window: panel))
        drain(0.6) // Let the real toolbar polling timer fire while dragging.
        equal(panel.frame.origin, shifted(origin, -50, -80), "polling reset an active drag")
        handle.mouseUp(with: event(.leftMouseUp, at: shifted(pointer, -73, -105), window: panel))
        let dropped = shifted(origin, -73, -105)
        equal(panel.frame.origin, dropped, "actual release coordinates")
        equal(offset(defaults), NSPoint(x: -73, y: -105), "saved release offset")
        drain(0.6)
        equal(panel.frame.origin, dropped, "post-release timer must not snap back")

        toolbar.setSuppressed(true)
        expect(!panel.isVisible, "suppression should hide toolbar")
        toolbar.setSuppressed(false)
        equal(visibleToolbar().frame.origin, dropped, "restore after workspace suppression")
        frontmost = false
        toolbar.start()
        expect(!panel.isVisible, "toolbar should hide outside Outlook")
        frontmost = true
        toolbar.start()
        equal(visibleToolbar().frame.origin, dropped, "restore after app switch")

        // Exercise every real action target; the drag area must not cover buttons.
        var clicks = Array(repeating: 0, count: 6)
        toolbar.newAction = { clicks[0] += 1 }
        toolbar.replyAction = { clicks[1] += 1 }
        toolbar.replyAllAction = { clicks[2] += 1 }
        toolbar.forwardAction = { clicks[3] += 1 }
        toolbar.cancelAction = { clicks[4] += 1 }
        toolbar.calendarAction = { clicks[5] += 1 }
        let buttons = root.subviews.compactMap { $0 as? NSButton }.sorted { $0.frame.minX < $1.frame.minX }
        expect(buttons.count == 6, "lost an action button")
        for button in buttons {
            expect(root.hitTest(NSPoint(x: button.frame.midX, y: button.frame.midY)) === button, "drag handle covers a button")
            button.performClick(nil)
        }
        expect(clicks == Array(repeating: 1, count: 6), "action routing changed")
        equal(offset(defaults), NSPoint(x: -73, y: -105), "buttons changed saved position")
        toolbar.stop()

        // A fresh defaults object and controller must restore the same preference.
        let reloadedDefaults = UserDefaults(suiteName: suite)!
        let recreated = OutlookToolbarButtonController(outlook: outlook, defaults: reloadedDefaults, outlookIsFrontmost: { true })
        recreated.start()
        let newPanel = visibleToolbar()
        equal(newPanel.frame.origin, dropped, "toolbar controller recreation")
        outlook.frame = originalFrame.offsetBy(dx: 20, dy: -20)
        recreated.start()
        equal(newPanel.frame.origin, shifted(dropped, 20, -20), "following Outlook")
        equal(offset(reloadedDefaults), NSPoint(x: -73, y: -105), "automatic following overwrote user offset")
        outlook.frame = NSRect(x: originalFrame.minX, y: originalFrame.minY, width: 200, height: 180)
        recreated.start()
        equal(offset(reloadedDefaults), NSPoint(x: -73, y: -105), "screen clamping overwrote user offset")
        outlook.frame = originalFrame
        recreated.start()
        equal(newPanel.frame.origin, dropped, "restoring original Outlook geometry")

        let newHandle = newPanel.contentView!.subviews.first { $0.identifier?.rawValue == "replyzen.outlookActions.dragHandle" }!
        let nextPointer = shifted(newPanel.frame.origin, 10, 17)
        newHandle.mouseDown(with: event(.leftMouseDown, at: nextPointer, window: newPanel))
        newHandle.mouseDragged(with: event(.leftMouseDragged, at: shifted(nextPointer, -12, -14), window: newPanel))
        recreated.setSuppressed(true) // Interrupted drag must save its latest point.
        equal(offset(reloadedDefaults), NSPoint(x: -85, y: -119), "interrupted gesture lost its position")
        recreated.setSuppressed(false)
        equal(newPanel.frame.origin, shifted(dropped, -12, -14), "restore after interrupted gesture")
        recreated.stop()
        print("PASS: toolbar hit testing, mouse down/drag/up, polling, suppression, app switch, persisted reload, following/clamping and all six actions")
    }
}
