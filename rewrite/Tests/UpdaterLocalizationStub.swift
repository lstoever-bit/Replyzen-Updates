import Foundation
enum L10n {
    enum Language: String { case german = "de" }
    static var language: Language { .german }
    static func tr(_ value: String, _ args: CVarArg...) -> String { value }
    static func source(_ value: String, _ args: CVarArg...) -> String { value }
    static func render(_ value: String) -> String { value }
    static func diagnostic(_ value: String) -> String { value }
}
