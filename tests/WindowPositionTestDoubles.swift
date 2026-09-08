import AppKit
import SwiftUI
import Combine

// Only surrounding services/content are stubbed. Tests compile and execute the
// exact production FloatingPanelController and OutlookToolbarButtonController.
// No Outlook automation, credentials, mail content or network calls are used.
final class AppState: ObservableObject {
    enum Stage { case startup, instruction, calendarPreview, preview, apiKey, needsAccessibility, error, generating, updating, inserting, success, idle }
    enum OutputMode { case reply, newMail, forward, calendar }
    @Published var stage: Stage = .error
    @Published var outputMode: OutputMode = .reply
    @Published var googleNeedsOAuthCredentials = false
    @Published var googleConnectedEmail = ""
    @Published var calendarWarning = ""
    var instruction = ""
}
struct OverlayView: View {
    @ObservedObject var state: AppState
    var body: some View { Color.clear }
}
enum ReplyZenBrand { static let displayName = "ReplyZen" }
enum L10n {
    static func render(_ value: String) -> String { value }
    static func source(_ value: String) -> String { value }
}
final class OutlookAccessibility {
    var frame: NSRect?
    var trusted = true
    func isTrusted() -> Bool { trusted }
    func focusedWindowFrameInAppKitCoordinates() -> NSRect? { frame }
}
