import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Only the configuration types needed by OpenAIClient; no UI or credentials.
enum ReplyTone { var apiInstruction: String { "Test tone" } }
enum AppState { enum ReplyLanguage { case german, usEnglish, spanish } }
enum CalendarManager {
    static let eventTimeZoneIdentifier = "Europe/Berlin"
    static let eventTimeZone = TimeZone(identifier: eventTimeZoneIdentifier)!
}
