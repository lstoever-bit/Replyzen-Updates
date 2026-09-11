import Foundation

final class OpenAIClient {
    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? {
            L10n.isAppMessage(message) ? message : L10n.source("Anfrage fehlgeschlagen. Technische Details: {0}", message)
        }
    }

    struct ReplyDraft: Decodable {
        let body: String
        let html: String?
    }

    func generateReply(
        apiKey: String,
        mailText: String,
        instruction: String,
        instructionHTML: String,
        tone: ReplyTone,
        language: AppState.ReplyLanguage,
        compact: Bool,
        completion: @escaping (Result<ReplyDraft, Error>) -> Void
    ) {
        var systemInstructions = [
            "Draft an email reply for the user.",
            "Return ONLY valid JSON with exactly these keys: body, html.",
            "body is the plain text final reply.",
            "html is the same final reply as a clean email safe HTML fragment. Use only p, br, strong, em, ul, ol and li. Do not use CSS, script, html or body tags.",
            "If the user's rich text instruction intentionally uses bold, italic, bullets or numbering, preserve that formatting in the final email where it makes sense.",
            "Be concise, natural, and appropriate for email.",
            tone.apiInstruction,
            restrainedDashInstruction,
            languageInstruction(for: language, purpose: "reply"),
            "Follow the user's instruction precisely. The language of the instruction is input only and must never override the selected output language.",
            "The USER INSTRUCTION is authoritative. Reflect every explicit requested point in the reply unless it conflicts with the source email or would require inventing facts. Do not silently omit user-provided instructions.",
            "Do not invent facts, promises, dates, attachments, or commitments.",
            "Do not add a subject line.",
            "Do not add a signature or the user's name."
        ]
        if compact {
            systemInstructions.append("COMPACT MODE IS ON: make the reply as short as possible while preserving the requested meaning. Prefer 1 to 3 short sentences and normally stay under 70 words.")
        }

        let richInstruction = instructionHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = "USER INSTRUCTION PLAIN:\n\(instruction)" +
            (richInstruction.isEmpty ? "" : "\n\nUSER INSTRUCTION HTML FORMATTING CUES:\n\(richInstruction)") +
            "\n\nEMAIL CONTENT:\n\(String(mailText.prefix(30_000)))"

        performRequest(
            apiKey: apiKey,
            instructions: systemInstructions.joined(separator: "\n"),
            input: input,
            maxOutputTokens: compact ? 340 : 700,
            lowVerbosity: true
        ) { result in
            switch result {
            case .success(let text):
                do { completion(.success(try Self.decodeReplyDraft(text))) }
                catch { completion(.failure(error)) }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func generateForwardNote(
        apiKey: String,
        mailText: String,
        instruction: String,
        instructionHTML: String,
        tone: ReplyTone,
        language: AppState.ReplyLanguage,
        compact: Bool,
        completion: @escaping (Result<ReplyDraft, Error>) -> Void
    ) {
        var systemInstructions = [
            "Draft the short note that the user will place above an existing forwarded email thread.",
            "Return ONLY valid JSON with exactly these keys: body, html.",
            "body is the plain text forwarding note only.",
            "html is the same note as a clean email safe HTML fragment. Use only p, br, strong, em, ul, ol and li. Do not use CSS, script, html or body tags.",
            "If the user's rich text instruction intentionally uses bold, italic, bullets or numbering, preserve that formatting in the final note where it makes sense.",
            "The original email thread and attachments will be preserved by Outlook below this note. Do not reproduce or summarize the whole forwarded thread unless the user explicitly asks for that.",
            "Do not invent a recipient. Do not add To, CC, BCC or a subject line.",
            "Do not add a signature or the user's name unless explicitly requested.",
            "Be concise, natural, and appropriate for email.",
            tone.apiInstruction,
            restrainedDashInstruction,
            languageInstruction(for: language, purpose: "forwarding note"),
            "Follow the user's instruction precisely. The language of the instruction is input only and must never override the selected output language.",
            "Do not invent facts, promises, dates, attachments, or commitments."
        ]
        if compact {
            systemInstructions.append("COMPACT MODE IS ON: make the forwarding note as short as possible while preserving the requested meaning. Prefer 1 to 3 short sentences and normally stay under 70 words.")
        }

        let richInstruction = instructionHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = "USER INSTRUCTION PLAIN:\n\(instruction)" +
            (richInstruction.isEmpty ? "" : "\n\nUSER INSTRUCTION HTML FORMATTING CUES:\n\(richInstruction)") +
            "\n\nEMAIL BEING FORWARDED:\n\(String(mailText.prefix(30_000)))"

        performRequest(
            apiKey: apiKey,
            instructions: systemInstructions.joined(separator: "\n"),
            input: input,
            maxOutputTokens: compact ? 340 : 700,
            lowVerbosity: true
        ) { result in
            switch result {
            case .success(let text):
                do { completion(.success(try Self.decodeReplyDraft(text))) }
                catch { completion(.failure(error)) }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func generateQuickDecline(
        apiKey: String,
        mailText: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let systemInstructions = [
            "Draft a very short, friendly decline as an email reply.",
            "Automatically detect the language of the latest relevant incoming message and write the reply in that same language.",
            "If the thread mixes languages, use the language of the most recent request that is being declined.",
            "Keep it warm, polite and concise: normally 1-3 short sentences.",
            restrainedDashInstruction,
            "Clearly decline the request or invitation, but do not invent a reason, excuse, date, promise or alternative unless it is explicitly supported by the email.",
            "Do not add a subject line, greeting-only filler, signature or the user's name.",
            "Return only the reply text."
        ].joined(separator: "\n")

        performRequest(
            apiKey: apiKey,
            instructions: systemInstructions,
            input: "EMAIL THREAD:\n\(String(mailText.prefix(30_000)))",
            model: "gpt-5.6-luna",
            reasoningEffort: "none",
            maxOutputTokens: 180,
            lowVerbosity: true,
            completion: completion
        )
    }

    struct NewMailDraft: Decodable {
        let subject: String
        let body: String
        let html: String?
    }

    func generateNewMail(
        apiKey: String,
        instruction: String,
        instructionHTML: String,
        tone: ReplyTone,
        language: AppState.ReplyLanguage,
        compact: Bool,
        completion: @escaping (Result<NewMailDraft, Error>) -> Void
    ) {
        var systemInstructions = [
            "Draft a new email for the user based only on the user's instruction.",
            "Return ONLY valid JSON with exactly these keys: subject, body, html.",
            "subject: write a short useful email subject in the selected output language, ideally 2 to 7 words. Do not prefix it with Subject, Betreff, Re or Fwd.",
            "body: write the actual email body only as plain text. Do not repeat the subject in the body.",
            "html: the same final body as a clean email safe HTML fragment. Use only p, br, strong, em, ul, ol and li. Do not use CSS, script, html or body tags.",
            "If the user's rich text instruction intentionally uses bold, italic, bullets or numbering, preserve that formatting in the final email where it makes sense.",
            "Be concise, natural, and appropriate for email.",
            tone.apiInstruction,
            languageInstruction(for: language, purpose: "email subject and body"),
            restrainedDashInstruction,
            "Follow the user's instruction precisely. The language of the instruction is input only and must never override the selected output language.",
            "Do not invent facts, promises, dates, attachments, recipients, or commitments that the user did not provide.",
            "Do not add a signature or the user's name unless the user explicitly asks for it."
        ]
        if compact {
            systemInstructions.append("COMPACT MODE IS ON: make the body as short as possible while preserving the requested meaning. Prefer 2 to 4 short sentences and normally stay under 80 words.")
        }

        let richInstruction = instructionHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = "USER INSTRUCTION PLAIN:\n\(instruction)" +
            (richInstruction.isEmpty ? "" : "\n\nUSER INSTRUCTION HTML FORMATTING CUES:\n\(richInstruction)")

        performRequest(
            apiKey: apiKey,
            instructions: systemInstructions.joined(separator: "\n"),
            input: input,
            maxOutputTokens: compact ? 380 : 760,
            lowVerbosity: true
        ) { result in
            switch result {
            case .success(let text):
                do { completion(.success(try Self.decodeNewMailDraft(text))) }
                catch { completion(.failure(error)) }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private var restrainedDashInstruction: String {
        "Avoid hyphens, en dashes, and em dashes in normal prose. Use them only when absolutely necessary for correctness or when preserving exact source text such as names, dates, URLs, email addresses, or reference numbers. Prefer commas, periods, or separate sentences instead."
    }

    private static func decodeReplyDraft(_ text: String) throws -> ReplyDraft {
        let cleaned = ResponseJSON.cleanedText(text)
        guard let data = cleaned.data(using: .utf8) else {
            throw APIError(message: L10n.source("OpenAI hat keinen gültigen Antwortentwurf geliefert."))
        }
        do {
            let draft = try JSONDecoder().decode(ReplyDraft.self, from: data)
            guard !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw APIError(message: L10n.source("OpenAI hat keinen Antworttext geliefert."))
            }
            return draft
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError(message: L10n.source("OpenAI hat den Antwortentwurf nicht im erwarteten Format geliefert."))
        }
    }

    private static func decodeNewMailDraft(_ text: String) throws -> NewMailDraft {
        let cleaned = ResponseJSON.cleanedText(text)
        guard let data = cleaned.data(using: .utf8) else {
            throw APIError(message: L10n.source("OpenAI hat keinen gültigen Mailentwurf geliefert."))
        }
        do {
            let draft = try JSONDecoder().decode(NewMailDraft.self, from: data)
            guard !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw APIError(message: L10n.source("OpenAI hat keinen Mailtext geliefert."))
            }
            return draft
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError(message: L10n.source("OpenAI hat den Mailentwurf nicht im erwarteten Format geliefert."))
        }
    }

    func summarizeThread(
        apiKey: String,
        mailText: String,
        language: AppState.ReplyLanguage,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let systemInstructions = [
            "Summarize the full email thread for the user. Do not draft an email reply.",
            languageInstruction(for: language, purpose: "summary"),
            "Be concise, clear, and structured.",
            restrainedDashInstruction,
            "Capture the key points, decisions or commitments, open questions, and action items or next steps.",
            "Preserve names, dates, amounts, and deadlines only when they are relevant.",
            "Do not invent facts or infer commitments that are not supported by the email thread.",
            "Prefer short bullet points unless the thread is so short that a brief paragraph is clearer.",
            "Return only the summary."
        ].joined(separator: "\n")

        performRequest(
            apiKey: apiKey,
            instructions: systemInstructions,
            input: "EMAIL THREAD:\n\(String(mailText.prefix(30_000)))",
            completion: completion
        )
    }

    struct CalendarSuggestion: Decodable {
        let title: String
        let description: String
        let start: String?
        let end: String?
        let confidence: String?
    }

    func createCalendarSuggestion(
        apiKey: String,
        mailText: String,
        language: AppState.ReplyLanguage,
        completion: @escaping (Result<CalendarSuggestion, Error>) -> Void
    ) {
        let nowFormatter = ISO8601DateFormatter()
        nowFormatter.timeZone = CalendarManager.eventTimeZone
        let now = nowFormatter.string(from: Date())
        let timezone = CalendarManager.eventTimeZoneIdentifier
        let titleLanguage: String
        let strictLanguageInstruction: String
        switch language {
        case .german:
            titleLanguage = "German"
            strictLanguageInstruction = "OUTPUT LANGUAGE IS GERMAN. The title and description MUST be written in German, regardless of the language used in the email thread."
        case .usEnglish:
            titleLanguage = "US English"
            strictLanguageInstruction = "OUTPUT LANGUAGE IS US ENGLISH. The title and description MUST be written in natural US English, regardless of the language used in the email thread. Translate ordinary descriptive words; preserve only true proper names such as people, companies, products, and projects."
        case .spanish:
            titleLanguage = "Spanish"
            strictLanguageInstruction = "OUTPUT LANGUAGE IS SPANISH. The title and description MUST be written in natural Spanish, regardless of the language used in the email thread. Translate ordinary descriptive words; preserve only true proper names such as people, companies, products, and projects."
        }

        let systemInstructions = [
            "Create a calendar event suggestion from the selected Outlook item. The item may be a normal email thread or an Outlook meeting invitation.",
            "Return ONLY valid JSON with exactly these keys: title, description, start, end, confidence.",
            "title: the shortest useful calendar title possible, ideally 1-4 words, maximum 6 words. No filler such as Meeting, Call, Appointment, Termin unless it is necessary to understand the event.",
            "description: an extremely compact description of what the appointment is about. Prefer one short sentence or a few compact phrases, maximum 180 characters. No greeting, no sign-off, no generic filler, no repeated title. Include only information useful when opening the calendar event later.",
            strictLanguageInstruction,
            restrainedDashInstruction,
            "Write title and description in \(titleLanguage). Preserve important project or person names, but never copy the source language merely because the thread uses it.",
            "start and end: ISO-8601 timestamps with timezone offset, or null.",
            "Use a date/time if one future appointment time is clearly agreed, clearly proposed, or explicitly scheduled in an Outlook meeting invitation. If several dates/times are possible or the timing is ambiguous, set start and end to null.",
            "If a start time is clear but no end time or duration is given, set end to 30 minutes after start.",
            "confidence must be one of explicit, ambiguous, missing.",
            "Do not invent a date, time, attendee, location, or commitment.",
            "Default calendar timezone is Europe/Berlin (Central European time: CET/CEST). Interpret date and time references in this timezone by default. If the email explicitly states another timezone, convert the resulting event time to Europe/Berlin.",
            "Current time in \(timezone) is \(now). Resolve explicit relative dates such as tomorrow using this context."
        ].joined(separator: "\n")

        performRequest(
            apiKey: apiKey,
            instructions: systemInstructions,
            input: "SELECTED OUTPUT LANGUAGE: \(titleLanguage)\n\nOUTLOOK ITEM CONTEXT:\n\(String(mailText.prefix(30_000)))",
            model: "gpt-5.6-luna",
            reasoningEffort: "none",
            maxOutputTokens: 320,
            lowVerbosity: true
        ) { result in
            switch result {
            case .success(let text):
                do {
                    completion(.success(try Self.decodeCalendarSuggestion(text)))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private static func decodeCalendarSuggestion(_ text: String) throws -> CalendarSuggestion {
        let cleaned = ResponseJSON.cleanedText(text)
        guard let data = cleaned.data(using: .utf8) else {
            throw APIError(message: L10n.source("OpenAI hat keinen gültigen Terminvorschlag geliefert."))
        }
        do {
            return try JSONDecoder().decode(CalendarSuggestion.self, from: data)
        } catch {
            throw APIError(message: L10n.source("OpenAI hat den Terminvorschlag nicht im erwarteten Format geliefert."))
        }
    }


    private func languageInstruction(for language: AppState.ReplyLanguage, purpose: String) -> String {
        switch language {
        case .german:
            return "FINAL OUTPUT LANGUAGE IS GERMAN. Write the entire \(purpose) in natural German. The USER INSTRUCTION may be written in any language; treat its language only as input and translate its requested meaning into German. Never switch the final email to another language because the instruction itself is written in that language. Preserve exact names, brands, URLs, email addresses and explicitly requested verbatim quotations."
        case .usEnglish:
            return "FINAL OUTPUT LANGUAGE IS US ENGLISH. Write the entire \(purpose) in natural US English using American spelling and phrasing. The USER INSTRUCTION may be written in any language; treat its language only as input and translate its requested meaning into US English. Never switch the final email to German or another language because the instruction itself is written in that language. Preserve exact names, brands, URLs, email addresses and explicitly requested verbatim quotations."
        case .spanish:
            return "FINAL OUTPUT LANGUAGE IS SPANISH. Write the entire \(purpose) in natural Spanish. The USER INSTRUCTION may be written in any language; treat its language only as input and translate its requested meaning into Spanish. Never switch the final email to German, English or another language because the instruction itself is written in that language. Preserve exact names, brands, URLs, email addresses and explicitly requested verbatim quotations."
        }
    }

    private func performRequest(
        apiKey: String,
        instructions: String,
        input: Any,
        model: String = "gpt-5.6-luna",
        reasoningEffort: String? = "none",
        maxOutputTokens: Int? = nil,
        lowVerbosity: Bool = false,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let url = URL(string: "https://api.openai.com/v1/responses") else {
            completion(.failure(APIError(message: L10n.source("Ungültige OpenAI-URL."))))
            return
        }

        var payload: [String: Any] = [
            "model": model,
            "store": false,
            "instructions": instructions,
            "input": input
        ]
        if let reasoningEffort {
            payload["reasoning"] = ["effort": reasoningEffort]
        }
        if let maxOutputTokens {
            payload["max_output_tokens"] = maxOutputTokens
        }
        if lowVerbosity {
            payload["text"] = ["verbosity": "low"]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let http = response as? HTTPURLResponse, let data else {
                completion(.failure(APIError(message: L10n.source("Keine Antwort von OpenAI erhalten."))))
                return
            }

            guard (200..<300).contains(http.statusCode) else {
                let message = Self.extractErrorMessage(from: data) ?? L10n.source("OpenAI-Fehler HTTP {0}.", http.statusCode)
                completion(.failure(APIError(message: message)))
                return
            }

            do {
                let text = try Self.extractOutputText(from: data)
                completion(.success(text))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }

    private static func extractOutputText(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? [[String: Any]] else {
            throw APIError(message: L10n.source("OpenAI hat ein unerwartetes Antwortformat geliefert."))
        }

        var pieces: [String] = []
        for item in output {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content {
                if part["type"] as? String == "output_text",
                   let text = part["text"] as? String {
                    pieces.append(text)
                }
            }
        }

        let result = pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            throw APIError(message: L10n.source("OpenAI hat keinen Antworttext geliefert."))
        }
        return result
    }
}
