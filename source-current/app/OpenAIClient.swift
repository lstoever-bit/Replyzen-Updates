import Foundation

final class OpenAIClient {
    private let fileIOQueue = DispatchQueue(label: "com.lstoever.replyzen.file-io", qos: .userInitiated)

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
            "Create a calendar event suggestion from the email thread.",
            "Return ONLY valid JSON with exactly these keys: title, description, start, end, confidence.",
            "title: the shortest useful calendar title possible, ideally 1-4 words, maximum 6 words. No filler such as Meeting, Call, Appointment, Termin unless it is necessary to understand the event.",
            "description: an extremely compact description of what the appointment is about. Prefer one short sentence or a few compact phrases, maximum 180 characters. No greeting, no sign-off, no generic filler, no repeated title. Include only information useful when opening the calendar event later.",
            strictLanguageInstruction,
            restrainedDashInstruction,
            "Write title and description in \(titleLanguage). Preserve important project or person names, but never copy the source language merely because the thread uses it.",
            "start and end: ISO-8601 timestamps with timezone offset, or null.",
            "Use a date/time only if one future appointment time is clearly agreed or clearly proposed in the thread. If several dates/times are possible or the timing is ambiguous, set start and end to null.",
            "If a start time is clear but no end time or duration is given, set end to 30 minutes after start.",
            "confidence must be one of explicit, ambiguous, missing.",
            "Do not invent a date, time, attendee, location, or commitment.",
            "Default calendar timezone is Europe/Berlin (Central European time: CET/CEST). Interpret date and time references in this timezone by default. If the email explicitly states another timezone, convert the resulting event time to Europe/Berlin.",
            "Current time in \(timezone) is \(now). Resolve explicit relative dates such as tomorrow using this context."
        ].joined(separator: "\n")

        performRequest(
            apiKey: apiKey,
            instructions: systemInstructions,
            input: "SELECTED OUTPUT LANGUAGE: \(titleLanguage)\n\nEMAIL THREAD:\n\(String(mailText.prefix(30_000)))",
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


    struct PaymentSuggestion: Decodable {
        let recipient: String?
        let iban: String?
        let bic: String?
        let amount: String?
        let currency: String?
        let purpose: String?
        let confidence: String?
    }

    func createPaymentSuggestion(
        apiKey: String,
        mailText: String,
        fileURLs: [URL],
        fallbackAttachmentText: String,
        completion: @escaping (Result<PaymentSuggestion, Error>) -> Void
    ) {
        let systemInstructions = [
            "Extract bank transfer details from the supplied email and invoice PDF files.",
            "The PDF invoice is the PRIMARY SOURCE. Read the PDF itself, including page layout, tables and scanned/visual content. Use the email only as supporting context.",
            "Return ONLY valid JSON with exactly these keys: recipient, iban, bic, amount, currency, purpose, confidence.",
            "Never invent or guess banking details. If a field is not clearly supported, return null for that field.",
            "recipient: exact payee/account holder name from the invoice.",
            "iban: exact IBAN, preferably without spaces. Preserve every character accurately.",
            "bic: exact BIC/SWIFT if stated, otherwise null.",
            "amount: exact amount that is currently payable, digits and decimal separator only, without currency symbol.",
            "currency: ISO currency code such as EUR only when supported by the source.",
            "purpose: shortest useful payment reference, prioritizing the invoice number, customer/reference number or explicitly requested payment reference.",
            "confidence must be one of high, medium, low.",
            "If the email conflicts with the invoice PDF, prefer the invoice PDF unless the email explicitly states corrected payment details. If there is still ambiguity, return null for the conflicting field and confidence low.",
            "This is extraction only. Never initiate, authorize or imply that a payment has been made."
        ].joined(separator: "\n")

        let pdfs = Array(fileURLs.filter { $0.pathExtension.lowercased() == "pdf" }.prefix(3))
        uploadFilesSequentially(apiKey: apiKey, urls: pdfs) { [weak self] uploadResult in
            guard let self else { return }

            switch uploadResult {
            case .failure(let error):
                completion(.failure(error))

            case .success(let fileIDs):
                var contextText = "EMAIL CONTEXT:\n\(String(mailText.prefix(18_000)))"
                if fileIDs.isEmpty && !fallbackAttachmentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    contextText += "\n\nFALLBACK LOCAL ATTACHMENT TEXT (only because no PDF file was available):\n\(String(fallbackAttachmentText.prefix(24_000)))"
                }

                var content: [[String: Any]] = [
                    ["type": "input_text", "text": contextText]
                ]
                for fileID in fileIDs {
                    content.append([
                        "type": "input_file",
                        "file_id": fileID,
                        "detail": "auto"
                    ])
                }

                let input: [[String: Any]] = [[
                    "role": "user",
                    "content": content
                ]]

                self.performRequest(
                    apiKey: apiKey,
                    instructions: systemInstructions,
                    input: input,
                    model: "gpt-5.6-luna",
                    reasoningEffort: "none",
                    maxOutputTokens: 320,
                    lowVerbosity: true
                ) { result in
                    // Files uploaded for invoice parsing are temporary in practice: remove
                    // them immediately after the response, even when parsing fails.
                    fileIDs.forEach { self.deleteUploadedFile(apiKey: apiKey, fileID: $0) }

                    switch result {
                    case .success(let text):
                        do {
                            completion(.success(try Self.decodePaymentSuggestion(text)))
                        } catch {
                            completion(.failure(error))
                        }
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    private func uploadFilesSequentially(
        apiKey: String,
        urls: [URL],
        index: Int = 0,
        collected: [String] = [],
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        guard index < urls.count else {
            completion(.success(collected))
            return
        }

        uploadFile(apiKey: apiKey, url: urls[index]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let fileID):
                self.uploadFilesSequentially(
                    apiKey: apiKey,
                    urls: urls,
                    index: index + 1,
                    collected: collected + [fileID],
                    completion: completion
                )
            case .failure(let error):
                collected.forEach { self.deleteUploadedFile(apiKey: apiKey, fileID: $0) }
                completion(.failure(error))
            }
        }
    }

    private func uploadFile(
        apiKey: String,
        url: URL,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        // Preparing a PDF/multipart body must never block the UI thread.
        fileIOQueue.async {
            self.prepareAndUploadFile(apiKey: apiKey, url: url, completion: completion)
        }
    }

    private func prepareAndUploadFile(
        apiKey: String,
        url: URL,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let endpoint = URL(string: "https://api.openai.com/v1/files") else {
            completion(.failure(APIError(message: L10n.source("Ungültige OpenAI-Datei-URL."))))
            return
        }

        let fileData: Data
        do {
            fileData = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            completion(.failure(APIError(message: L10n.source("Der PDF-Anhang konnte nicht gelesen werden: {0}", url.lastPathComponent))))
            return
        }

        let boundary = "Replyzen-\(UUID().uuidString)"
        let originalFilename = url.lastPathComponent.replacingOccurrences(of: "\"", with: "_")
        let safeFilename: String
        if url.pathExtension.lowercased() == "pdf" {
            let stem = URL(fileURLWithPath: originalFilename).deletingPathExtension().lastPathComponent
            safeFilename = (stem.isEmpty ? "invoice" : stem) + ".pdf"
        } else {
            safeFilename = originalFilename
        }
        var body = Data()
        body.reserveCapacity(fileData.count + 1024)

        func append(_ string: String) {
            if let data = string.data(using: .utf8) {
                body.append(data)
            }
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"purpose\"\r\n\r\n")
        append("user_data\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename)\"\r\n")
        append("Content-Type: application/pdf\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                completion(.failure(APIError(message: L10n.source("Keine Antwort beim PDF-Upload von OpenAI erhalten."))))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = Self.extractErrorMessage(from: data) ?? L10n.source("OpenAI-PDF-Upload fehlgeschlagen (HTTP {0}).", http.statusCode)
                completion(.failure(APIError(message: message)))
                return
            }

            do {
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let fileID = object?["id"] as? String, !fileID.isEmpty else {
                    throw APIError(message: L10n.source("OpenAI hat keine Datei-ID für den PDF-Anhang geliefert."))
                }
                completion(.success(fileID))
            } catch let error as APIError {
                completion(.failure(error))
            } catch {
                completion(.failure(APIError(message: L10n.source("Die OpenAI-Antwort auf den PDF-Upload war ungültig."))))
            }
        }.resume()
    }

    private func deleteUploadedFile(apiKey: String, fileID: String) {
        guard let url = URL(string: "https://api.openai.com/v1/files/\(fileID)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request).resume()
    }

    private static func decodePaymentSuggestion(_ text: String) throws -> PaymentSuggestion {
        let cleaned = ResponseJSON.cleanedText(text)
        guard let data = cleaned.data(using: .utf8) else {
            throw APIError(message: L10n.source("OpenAI hat keine gültigen Überweisungsdaten geliefert."))
        }
        do {
            return try JSONDecoder().decode(PaymentSuggestion.self, from: data)
        } catch {
            throw APIError(message: L10n.source("OpenAI hat die Überweisungsdaten nicht im erwarteten Format geliefert."))
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
