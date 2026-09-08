import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let replyZenLanguageDidChange = Notification.Name("ReplyZen.InterfaceLanguageDidChange")
}

final class AppLocalization: ObservableObject {
    static let shared = AppLocalization()
    private let defaults: UserDefaults
    @Published var language: InterfaceLanguage {
        didSet {
            guard language != oldValue else { return }
            precondition(Thread.isMainThread)
            L10n.select(language)
            defaults.set(language.rawValue, forKey: L10n.preferenceKey)
            // Per-app language only; never changes macOS or Outlook preferences.
            // System-owned panels pick this up on the next app launch.
            defaults.set([language.rawValue], forKey: "AppleLanguages")
            NotificationCenter.default.post(name: .replyZenLanguageDidChange, object: self)
        }
    }
    var locale: Locale { language.locale }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: L10n.preferenceKey) ?? "de"
        language = InterfaceLanguage(rawValue: stored) ?? .german
        L10n.select(language)
    }
}

struct InterfaceLanguagePicker: View {
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.tr("App-Sprache"), selection: $localization.language) {
                ForEach(InterfaceLanguage.allCases) { language in
                    // Autonyms stay recognizable regardless of the chosen language.
                    Text(verbatim: language.nativeName).tag(language)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("replyzen.interfaceLanguage")
            Text(L10n.tr("Gilt für die gesamte Oberfläche. Die Sprache deiner E-Mails bleibt unabhängig davon."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .environment(\.locale, localization.locale)
    }
}

struct InterfaceSettingsView: View {
    @ObservedObject private var localization = AppLocalization.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.tr("Einstellungen")).font(.title2.weight(.semibold))
            InterfaceLanguagePicker()
            Divider()
            Text(L10n.tr("Die Auswahl wird automatisch gespeichert."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 220, alignment: .topLeading)
        .environment(\.locale, localization.locale)
    }
}
