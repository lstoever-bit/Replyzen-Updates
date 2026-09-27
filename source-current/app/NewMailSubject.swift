import Foundation

/// An absent subject must not discard a valid message. The fallback is extractive,
/// local, and never invents a date, person or promise or sends another API request.
enum NewMailSubject {
    private static func oneLine(_ text: String) -> String {
        let visible = text.replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        return visible.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    static func resolve(_ proposed: String?, body: String, language: String) -> String {
        let provided = oneLine(proposed ?? "")
        if !provided.isEmpty { return provided }
        let greetings = ["hallo", "hi", "hello", "dear", "guten morgen", "guten tag", "guten abend", "sehr geehrte", "sehr geehrter", "hola", "estimado", "estimada", "buenos dias", "buenas tardes"]
        let closings = ["mit freundlichen", "viele grusse", "liebe grusse", "best regards", "kind regards", "sincerely", "saludos", "atentamente"]
        for raw in body.components(separatedBy: .newlines) {
            var line = oneLine(raw)
            if line.isEmpty { continue }
            let folded = line.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if closings.contains(where: { folded == $0 || folded.hasPrefix($0 + " ") }) { break }
            if greetings.contains(where: { folded == $0 || folded.hasPrefix($0 + " ") || folded.hasPrefix($0 + ",") }) {
                guard let comma = line.firstIndex(of: ",") else { continue }
                line = String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
            }
            if let stop = line.firstIndex(where: { ".!?".contains($0) }), line.distance(from: line.startIndex, to: stop) >= 12 {
                line = String(line[..<stop])
            }
            if line.count > 100 {
                line = String(line.prefix(100))
                if let space = line.lastIndex(of: " "), line.distance(from: line.startIndex, to: space) > 65 {
                    line = String(line[..<space])
                }
            }
            if !line.isEmpty { return line }
        }
        if language.lowercased().hasPrefix("es") { return "Mensaje" }
        if language.lowercased().hasPrefix("en") { return "Message" }
        return "Nachricht"
    }
}
