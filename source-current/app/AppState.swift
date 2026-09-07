import Foundation
import Combine

final class AppState: ObservableObject {
    enum OutputMode: String, CaseIterable, Identifiable, Equatable {
        case reply
        case newMail
        case calendar
        case payment

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .reply: return "Reply"
            case .newMail: return "New Mail"
            case .calendar: return "Termin"
            case .payment: return "Überweisung"
            }
        }
    }

    enum ReplyLanguage: Equatable {
        case german
        case usEnglish

        var displayName: String {
            switch self {
            case .german: return "Deutsch"
            case .usEnglish: return "US English"
            }
        }
    }

    enum MailStatus: Equatable {
        case notChecked
        case loading
        case available
        case unavailable(String)
    }

    enum Stage: Equatable {
        case idle
        case startup
        case instruction
        case generating
        case updating
        case preview
        case calendarPreview
        case paymentPreview
        case inserting
        case success
        case needsAccessibility
        case apiKey
        case error
    }

    @Published var stage: Stage = .idle
    @Published var instruction: String = ""
    @Published var reply: String = ""
    @Published var errorMessage: String = ""
    @Published var apiKeyDraft: String = ""
    @Published var statusText: String = ""
    @Published var startupJoke: String = ""
    @Published var replyLanguage: ReplyLanguage = .german
    @Published var replyTone: ReplyTone = .friendly
    @Published var newMailCompact: Bool = false
    @Published var newMailSubject: String = ""
    @Published var selectedCommandName: String = "Custom"
    @Published var outputMode: OutputMode = .reply
    @Published var mailStatus: MailStatus = .notChecked
    @Published var calendarTitle: String = ""
    @Published var calendarNotes: String = ""
    @Published var calendarStart: Date = Date()
    @Published var calendarEnd: Date = Date().addingTimeInterval(30 * 60)
    @Published var calendarWarning: String = ""
    @Published var calendarOptions: [CalendarOption] = []
    @Published var selectedCalendarID: String = ""
    @Published var calendarListStatus: String = "Google-Kalender werden geladen …"
    @Published var googleNeedsOAuthCredentials: Bool = false
    @Published var googleClientIDDraft: String = ""
    @Published var googleClientSecretDraft: String = ""
    @Published var googleConnectedEmail: String = ""
    @Published var googleOAuthStatus: String = ""
    @Published var googleIsConnecting: Bool = false
    @Published var successMessage: String = ""
    @Published var paymentRecipient: String = ""
    @Published var paymentIBAN: String = ""
    @Published var paymentBIC: String = ""
    @Published var paymentAmount: String = ""
    @Published var paymentCurrency: String = "EUR"
    @Published var paymentPurpose: String = ""
    @Published var paymentSourceStatus: String = ""
    @Published var paymentWarning: String = ""

    var mailText: String = ""

    var generateAction: (() -> Void)?
    var insertAction: (() -> Void)?
    var createCalendarAction: (() -> Void)?
    var extractPaymentAction: (() -> Void)?
    var copyPaymentAction: (() -> Void)?
    var connectGoogleCalendarAction: (() -> Void)?
    var disconnectGoogleCalendarAction: (() -> Void)?
    var openGoogleCloudAction: (() -> Void)?
    var retryAction: (() -> Void)?
    var refreshMailAction: (() -> Void)?
    var closeAction: (() -> Void)?
    var saveAPIKeyAction: (() -> Void)?
    var openAccessibilityAction: (() -> Void)?
}
