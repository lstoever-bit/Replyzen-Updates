import AppKit

final class KeyboardController {
    func sendCommandR() {
        sendKey(code: 15, flags: .maskCommand)
    }

    func sendCommandShiftR() {
        sendKey(code: 15, flags: [.maskCommand, .maskShift])
    }

    func sendCommandN() {
        sendKey(code: 45, flags: .maskCommand)
    }

    func sendCommandJ() {
        sendKey(code: 38, flags: .maskCommand)
    }

    func sendCommandA() {
        sendKey(code: 0, flags: .maskCommand)
    }

    func sendCommandV() {
        sendKey(code: 9, flags: .maskCommand)
    }

    func sendCommandUp() {
        sendKey(code: 126, flags: .maskCommand)
    }

    func sendTab() {
        sendKey(code: 48, flags: [])
    }

    private func sendKey(code: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            return
        }

        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
