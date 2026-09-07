import Foundation
import AppKit
import ServiceManagement

final class LoginItemManager {
    @discardableResult
    func enableAtLoginIfPossible() -> Bool {
        guard #available(macOS 13.0, *) else { return false }

        switch SMAppService.mainApp.status {
        case .enabled:
            return true
        case .notRegistered, .requiresApproval, .notFound:
            do {
                try SMAppService.mainApp.register()
                return SMAppService.mainApp.status == .enabled
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
