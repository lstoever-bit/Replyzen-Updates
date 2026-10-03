import Foundation

// No accessibility, foreground PIDs, clipboard or synthetic keyboard events.
enum NativeMailMode: String, CaseIterable { case reply, replyAll, forward, newMail }

struct NativeMessageToken: Equatable {
    let localID: String
    let internetID: String
    let subject: String
}

struct NativeMailContext: Equatable {
    let token: NativeMessageToken
    let plainText: String
}

struct NativeAttachment: Equatable, Hashable {
    let name: String
    let size: Int
}

struct NativeDraftSnapshot: Equatable {
    let id: String
    let subject: String
    let html: String
    let plainText: String
    let attachments: [NativeAttachment]
    let isHTML: Bool
}

struct NativeMailRequest: Equatable {
    let operationID: UUID
    let mode: NativeMailMode
    let source: NativeMessageToken?
    let subject: String
    let note: String
    let noteHTML: String
    let reminderBCC: String?
}

enum NativeMailError: Error, LocalizedError, Equatable {
    case emptyNote, missingSource, busy, sourceChanged, invalidDraft
    case permissionDenied, unsupportedOutlook, notRunning
    case creationUncertain
    case verificationFailed(draftID: String)
    case draftNeedsReview(draftID: String)
    case transport(code: Int)

    var errorDescription: String? {
        switch self {
        case .emptyNote: return "Der Mailtext ist leer."
        case .missingSource: return "Bitte die Originalmail zuerst erneut laden."
        case .busy: return "Ein Entwurf wird bereits vorbereitet."
        case .sourceChanged: return "Die geladene Originalmail ist nicht mehr eindeutig verfuegbar. Bitte erneut laden."
        case .invalidDraft: return "Outlook hat keinen gueltigen Entwurf zurueckgegeben."
        case .permissionDenied: return "ReplyZen darf Outlook noch nicht steuern. Bitte die macOS-Freigabe unter Datenschutz & Sicherheit > Automation erlauben."
        case .unsupportedOutlook: return "Diese Outlook-Version bietet die benoetigte native Automationsschnittstelle nicht an. Die neue Uebergabe benoetigt klassisches Outlook fuer Mac."
        case .notRunning: return "Bitte Microsoft Outlook starten."
        case .creationUncertain: return "Outlook hat die Erstellung nicht bestaetigt. Bitte Entwuerfe pruefen; es wird nicht automatisch ein zweiter Entwurf angelegt. Dein Text bleibt in ReplyZen."
        case .verificationFailed(let id): return "Der Entwurf \(id) konnte nicht vollstaendig geprueft werden. Bitte direkt in Outlook pruefen. Dein Text bleibt in ReplyZen."
        case .draftNeedsReview(let id): return "Bitte den bereits erstellten Outlook-Entwurf \(id) pruefen. ReplyZen fuegt nicht automatisch erneut ein."
        case .transport(let code): return "Outlook-Automation meldet Fehler \(code). Dein Text bleibt in ReplyZen."
        }
    }
}

protocol NativeOutlookTransport: AnyObject {
    func capture() throws -> NativeMailContext
    func validateSource(_ token: NativeMessageToken) throws
    func sourceAttachments(_ token: NativeMessageToken) throws -> [NativeAttachment]
    func create(mode: NativeMailMode, source: NativeMessageToken?) throws -> String
    func readDraft(id: String) throws -> NativeDraftSnapshot
    func apply(id: String, expected: NativeDraftSnapshot, subject: String, html: String, reminderBCC: String?) throws
    func reveal(id: String) throws
}

// One transaction object per user generation. Once creation starts, it is never
// replayed automatically: a timeout may mean Outlook created the draft anyway.
final class NativeMailTransaction {
    enum State: Equatable { case ready, creating, draft(String), complete(String), uncertain, needsReview(String) }
    private(set) var state: State = .ready
    private(set) var frozenRequest: NativeMailRequest?
    private let transport: NativeOutlookTransport
    init(transport: NativeOutlookTransport) { self.transport = transport }

    func run(_ request: NativeMailRequest) throws -> String {
        guard !request.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeMailError.emptyNote }
        switch state {
        case .complete(let id):
            guard frozenRequest == request else { throw NativeMailError.draftNeedsReview(draftID: id) }
            try transport.reveal(id: id)
            return id
        case .uncertain: throw NativeMailError.creationUncertain
        case .needsReview(let id), .draft(let id): throw NativeMailError.draftNeedsReview(draftID: id)
        case .creating: throw NativeMailError.busy
        case .ready: break
        }
        if request.mode != .newMail {
            guard let source = request.source else { throw NativeMailError.missingSource }
            try transport.validateSource(source)
        }
        let sourceAttachments: [NativeAttachment]
        if request.mode == .forward, let source = request.source {
            sourceAttachments = try transport.sourceAttachments(source)
        } else { sourceAttachments = [] }
        frozenRequest = request
        state = .creating
        let id: String
        do {
            id = try transport.create(mode: request.mode, source: request.source)
            guard !id.isEmpty, id.allSatisfy({ $0.isNumber }) else { throw NativeMailError.invalidDraft }
        } catch let error as NativeMailError where [.permissionDenied, .notRunning, .unsupportedOutlook, .sourceChanged].contains(error) {
            // These errors are established before the native creation command.
            state = .ready
            frozenRequest = nil
            throw error
        } catch {
            state = .uncertain
            throw NativeMailError.creationUncertain
        }
        state = .draft(id)
        do {
            let before = try transport.readDraft(id: id)
            guard before.id == id, NativeMailComposition.includes(sourceAttachments, in: before.attachments) else {
                throw NativeMailError.invalidDraft
            }
            let subject = request.mode == .newMail
                ? NativeMailComposition.subject(request.subject, note: request.note) : before.subject
            let html = NativeMailComposition.prepend(note: request.note, html: request.noteHTML, to: before, operationID: request.operationID)
            try transport.apply(id: id, expected: before, subject: subject, html: html, reminderBCC: request.reminderBCC)
            let after = try transport.readDraft(id: id)
            guard NativeMailComposition.verify(note: request.note, subject: subject, before: before, after: after) else {
                throw NativeMailError.verificationFailed(draftID: id)
            }
            state = .complete(id)
            try transport.reveal(id: id)
            return id
        } catch {
            // Opening a validated draft can fail without invalidating its content.
            if state != .complete(id) { state = .needsReview(id) }
            throw NativeMailError.draftNeedsReview(draftID: id)
        }
    }
}

enum NativeMailComposition {
    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
    static func textHTML(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "<br>")
    }
    static func subject(_ supplied: String, note: String) -> String {
        let supplied = normalized(supplied)
        if !supplied.isEmpty { return String(supplied.prefix(160)) }
        let greetings = ["hallo", "hello", "hi ", "dear ", "sehr geehrt", "guten ", "moin", "hola"]
        let lines = note.components(separatedBy: .newlines).map(normalized).filter { !$0.isEmpty }
        let line = lines.first { value in !greetings.contains(where: { value.lowercased().hasPrefix($0) }) } ?? lines.first ?? "Nachricht"
        return String(line.prefix(100))
    }
    static func bodyRange(in html: String) -> Range<String.Index>? {
        guard let start = html.range(of: "(?is)<body(?:\\s[^>]*)?>", options: .regularExpression) else { return nil }
        return start
    }
    static func fragment(_ html: String, fallback: String) -> String {
        // Only prepared application HTML enters this function, never script source.
        let html = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if html.isEmpty { return textHTML(fallback) }
        if let start = bodyRange(in: html), let end = html.range(of: "(?is)</body\\s*>", options: .regularExpression, range: start.upperBound..<html.endIndex) {
            return String(html[start.upperBound..<end.lowerBound])
        }
        return html
    }
    static func prepend(note: String, html: String, to draft: NativeDraftSnapshot, operationID: UUID) -> String {
        let marker = "<!--replyzen-native-\(operationID.uuidString)-->"
        let newText = marker + "<div style=\"font-family:Calibri,Arial,sans-serif;font-size:10.5pt\">" + fragment(html, fallback: note) + "</div><br><br>"
        if draft.isHTML && !draft.html.isEmpty {
            if let body = bodyRange(in: draft.html) {
                var result = draft.html
                result.insert(contentsOf: newText, at: body.upperBound)
                return result // Original bytes, including CID image references, preserved.
            }
            return "<html><body>" + newText + draft.html + "</body></html>"
        }
        return "<html><body>" + newText + textHTML(draft.plainText) + "</body></html>"
    }
    static func verify(note: String, subject: String, before: NativeDraftSnapshot, after: NativeDraftSnapshot) -> Bool {
        guard before.id == after.id, normalized(subject) == normalized(after.subject),
              attachmentCounts(before.attachments) == attachmentCounts(after.attachments) else { return false }
        let text = normalized(after.plainText), original = normalized(before.plainText), newText = normalized(note)
        guard !newText.isEmpty, text.hasPrefix(newText) else { return false }
        // Preserve the complete quoted text (not just a larger body length).
        let rest = normalized(String(text.dropFirst(newText.count)))
        return original.isEmpty || rest == original
    }
    static func includes(_ expected: [NativeAttachment], in actual: [NativeAttachment]) -> Bool {
        let counts = attachmentCounts(actual)
        return attachmentCounts(expected).allSatisfy { counts[$0.key, default: 0] >= $0.value }
    }
    private static func attachmentCounts(_ attachments: [NativeAttachment]) -> [NativeAttachment: Int] {
        Dictionary(attachments.map { ($0, 1) }, uniquingKeysWith: +)
    }
}
