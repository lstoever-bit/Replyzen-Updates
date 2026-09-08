import AppKit
import Foundation

@main
struct LocalizationTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        precondition(L10n.catalog.count >= 250, "Bundled catalog missing")
        let languages = Set(InterfaceLanguage.allCases.map(\.rawValue))
        for (key, row) in L10n.catalog {
            precondition(Set(row.keys) == languages, "Missing language for \(key)")
            precondition(row.values.allSatisfy { !$0.isEmpty })
        }
        let cases: [(InterfaceLanguage, String, String)] = [
            (.english, "Settings", "Reply all"), (.german, "Einstellungen", "Allen antworten"),
            (.spanish, "Configuración", "Responder a todos")
        ]
        let canonical = L10n.source("Update verfügbar: {0}…", "9.9.1")
        let fileName = "Fertig {1} 100%.PDF"
        let fileMessage = L10n.source("Der PDF-Anhang konnte nicht gelesen werden: {0}", fileName)
        let nested = L10n.source("Google-Anmeldung fehlgeschlagen: {0}", L10n.diagnostic(L10n.source("Die Google-Anmeldung wurde abgebrochen.")))
        for (language, settings, replyAll) in cases {
            L10n.select(language)
            precondition(L10n.tr("Einstellungen") == settings)
            precondition(L10n.tr("Reply All") == replyAll)
            precondition(L10n.render(canonical).contains("9.9.1"))
            precondition(L10n.render(fileMessage).hasSuffix(fileName))
            precondition(L10n.render(nested).contains(L10n.tr("Die Google-Anmeldung wurde abgebrochen.")))
            precondition(L10n.render("Unmodified remote error: 429") == "Unmodified remote error: 429")
            // Ordinary values must never be translated even if equal to a UI key.
            precondition(L10n.tr("Empfänger: {0}", "Fertig").hasSuffix("Fertig"))
        }
        let suite = "ReplyZen.Localization.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); L10n.select(.german) }
        let settings = AppLocalization(defaults: defaults)
        settings.language = .spanish
        precondition(defaults.string(forKey: L10n.preferenceKey) == "es")
        precondition(defaults.stringArray(forKey: "AppleLanguages") == ["es"])
        let reloaded = AppLocalization(defaults: defaults)
        precondition(reloaded.language == .spanish)
        reloaded.language = .english
        precondition(L10n.language == .english)
        precondition(InterfaceLanguage.english.nativeName == "US English")
        precondition(InterfaceLanguage.german.nativeName == "Deutsch")
        precondition(InterfaceLanguage.spanish.nativeName == "Español")
        print("PASS: \(L10n.catalog.count) complete translation keys; all three languages; persistence; live diagnostics; interpolation safety")
    }
}
