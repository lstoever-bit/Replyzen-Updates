import Foundation

/// Interface language is deliberately separate from AppState.ReplyLanguage.
enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case english = "en-US"
    case german = "de"
    case spanish = "es"

    var id: String { rawValue }
    var nativeName: String {
        switch self {
        case .english: return "US English"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        }
    }
    var locale: Locale {
        Locale(identifier: self == .german ? "de_DE" : (self == .spanish ? "es_ES" : "en_US"))
    }
}

/// All app-owned copy is in Resources/Localization.json. Technical identifiers,
/// API prompts, outgoing mail, user-entered names and payment values are not keys.
enum L10n {
    static let preferenceKey = "ReplyZen.InterfaceLanguage"
    private static let lock = NSLock()
    private static var selected = InterfaceLanguage(rawValue:
        UserDefaults.standard.string(forKey: preferenceKey) ?? "de") ?? .german
    static let catalog: [String: [String: String]] = {
        var url = Bundle.main.url(forResource: "Localization", withExtension: "json")
        #if LOCALIZATION_TESTS
        if let path = ProcessInfo.processInfo.environment["REPLYZEN_TEST_CATALOG"] {
            url = URL(fileURLWithPath: path)
        }
        #endif
        guard let url, let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return value
    }()
    private static let placeholder = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)

    // The existing model stores status/error messages as String. Preserve the key
    // and typed arguments for those messages so a live language switch can redraw
    // them without touching model comparisons or any user-authored content.
    private struct Message {
        let key: String
        let arguments: [Argument]
    }
    private enum Argument {
        case text(String)
        case diagnostic(String)
        case date(DateValue)
    }
    struct Diagnostic { let text: String }
    struct DateValue {
        let date: Date
        let timeZone: TimeZone
        init(_ date: Date, timeZone: TimeZone) { self.date = date; self.timeZone = timeZone }
    }
    private static var messages: [String: Message] = [:]
    private static var messageOrder: [String] = []
    private static let messageLimit = 512

    static var language: InterfaceLanguage {
        lock.lock(); defer { lock.unlock() }
        return selected
    }
    static var locale: Locale { language.locale }
    static func select(_ language: InterfaceLanguage) {
        lock.lock(); selected = language; lock.unlock()
    }
    static func diagnostic(_ text: String) -> Diagnostic { Diagnostic(text: text) }

    static func tr(_ key: String, _ values: Any...) -> String {
        let language = self.language
        let template = catalog[key]?[language.rawValue] ?? key
        return substitute(template, arguments(values).map { value($0, language: language, depth: 0) })
    }

    /// Canonical, untranslated model value. Interpolations are recorded only for
    /// app-owned diagnostics, never for the editor's user text or API-key fields.
    static func source(_ key: String, _ values: Any...) -> String {
        guard !values.isEmpty else { return key }
        let args = arguments(values)
        let canonical = substitute(key, args.map { value($0, language: .german, depth: 0, translating: false) })
        lock.lock()
        if messages[canonical] == nil { messageOrder.append(canonical) }
        messages[canonical] = Message(key: key, arguments: args)
        while messageOrder.count > messageLimit {
            messages.removeValue(forKey: messageOrder.removeFirst())
        }
        lock.unlock()
        return canonical
    }

    static func render(_ message: String) -> String {
        render(message, language: language, depth: 0)
    }
    static func isAppMessage(_ message: String) -> Bool {
        if catalog[message] != nil { return true }
        lock.lock(); defer { lock.unlock() }
        return messages[message] != nil
    }
    private static func render(_ text: String, language: InterfaceLanguage, depth: Int) -> String {
        guard depth < 8 else { return text }
        if let translated = catalog[text]?[language.rawValue] { return translated }
        lock.lock(); let message = messages[text]; lock.unlock()
        guard let message else { return text }
        let template = catalog[message.key]?[language.rawValue] ?? message.key
        return substitute(template, message.arguments.map { value($0, language: language, depth: depth + 1) })
    }
    private static func arguments(_ values: [Any]) -> [Argument] {
        values.map {
            if let diagnostic = $0 as? Diagnostic { return .diagnostic(diagnostic.text) }
            if let date = $0 as? DateValue { return .date(date) }
            return .text(String(describing: $0))
        }
    }
    private static func value(_ argument: Argument, language: InterfaceLanguage, depth: Int,
                              translating: Bool = true) -> String {
        switch argument {
        case .text(let text): return text
        case .diagnostic(let text): return translating ? render(text, language: language, depth: depth) : text
        case .date(let date):
            let formatter = DateFormatter()
            formatter.locale = language.locale
            formatter.timeZone = date.timeZone
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date.date)
        }
    }
    private static func substitute(_ template: String, _ values: [String]) -> String {
        // Replace matches in the template, never in arguments that were inserted.
        // This preserves literal braces, percent signs, IBANs and user names.
        let result = NSMutableString(string: template)
        let range = NSRange(location: 0, length: (template as NSString).length)
        for match in placeholder.matches(in: template, range: range).reversed() {
            let token = (template as NSString).substring(with: match.range(at: 1))
            if let index = Int(token), values.indices.contains(index) {
                result.replaceCharacters(in: match.range, with: values[index])
            }
        }
        return result as String
    }
}
