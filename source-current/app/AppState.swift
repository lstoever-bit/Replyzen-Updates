import Foundation
import Combine

final class AppState: ObservableObject {
    enum OutputMode: String, CaseIterable, Identifiable, Equatable {
        case reply
        case newMail
        case forward
        case calendar

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .reply: return L10n.tr("Reply")
            case .newMail: return L10n.tr("New Mail")
            case .forward: return L10n.tr("Forward")
            case .calendar: return L10n.tr("Termin")
            }
        }
    }

    enum ReplyLanguage: Equatable, CaseIterable {
        case german
        case usEnglish
        case spanish

        var displayName: String {
            switch self {
            case .german: return L10n.tr("Deutsch")
            case .usEnglish: return L10n.tr("US English")
            case .spanish: return L10n.tr("Español")
            }
        }

        var defaultReplyInstruction: String {
            switch self {
            case .german: return "Kurz, freundlich und direkt antworten."
            case .usEnglish: return "Reply briefly, friendly and directly."
            case .spanish: return "Responder de forma breve, amable y directa."
            }
        }
    }

    enum ReplyScope: Equatable {
        case sender
        case all
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
        case inserting
        case success
        case needsAccessibility
        case apiKey
        case error
    }

    @Published var stage: Stage = .idle
    @Published var instruction: String = ""
    @Published var instructionHTML: String = ""
    @Published var reply: String = ""
    @Published var replyHTML: String = ""
    @Published var errorMessage: String = ""
    @Published var apiKeyDraft: String = ""
    @Published var statusText: String = ""
    @Published var startupJoke: String = ""
    @Published var replyLanguage: ReplyLanguage = .german
    @Published var replyScope: ReplyScope = .all
    @Published var replyTone: ReplyTone = .friendly
    @Published var newMailCompact: Bool = false
    @Published var previewBeforeChatGPT: Bool = UserDefaults.standard.bool(forKey: "ReplyZen.PreviewBeforeChatGPT") {
        didSet { UserDefaults.standard.set(previewBeforeChatGPT, forKey: "ReplyZen.PreviewBeforeChatGPT") }
    }
    @Published var reminderEnabled: Bool = false
    @Published var reminderDay: String = ReminderDay.nextCode()
    @Published var reminderTime: String = "06:00"
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
    @Published var calendarListStatus: String = L10n.source("Google-Kalender werden geladen …")
    @Published var googleNeedsOAuthCredentials: Bool = false
    @Published var googleClientIDDraft: String = ""
    @Published var googleClientSecretDraft: String = ""
    @Published var googleConnectedEmail: String = ""
    @Published var googleOAuthStatus: String = ""
    @Published var googleIsConnecting: Bool = false
    @Published var successMessage: String = ""

    var mailText: String = ""

    var generateAction: (() -> Void)?
    var insertAction: (() -> Void)?
    var createCalendarAction: (() -> Void)?
    var connectGoogleCalendarAction: (() -> Void)?
    var disconnectGoogleCalendarAction: (() -> Void)?
    var openGoogleCloudAction: (() -> Void)?
    var retryAction: (() -> Void)?
    var refreshMailAction: (() -> Void)?
    var closeAction: (() -> Void)?
    var saveAPIKeyAction: (() -> Void)?
    var openAccessibilityAction: (() -> Void)?
}
