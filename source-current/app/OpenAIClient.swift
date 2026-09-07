import Foundation

final class OpenAIClient {
    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func generateReply(
        apiKey: String,
        mailText: String,
        instruction: String,
        tone: ReplyTone,
        language: AppState.ReplyLanguage,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let systemInstructions = [
            "Draft an email reply for the user.",
            "Be concise, natural, and appropriate for email.",
            tone.apiInstruction,
            languageInstruction(for: language, purpose: "reply"),
            "Follow the user's instruction precisely.",
            "Do not invent facts, promises, dates, attachments, or commitments.",
            "Do not add a subject line.",
            "Do not add a signature or the user's name.",
            "Return only the reply text."
        ].joined(separator: "\n")

        performRequest(
            apiKey: apiKey,
            instructions: systemInstructions,
            input: "USER INSTRUCTION:\n\(instruction)\n\nEMAIL CONTENT:\n\(String(mailText.prefix(30_000)))",
            maxOutputTokens: 520,
            lowVerbosity: true,
            completion: completion
        )
    }

    struct NewMailDraft: Decodable {
        let subject: String
        let body: String
    }

    func generateNewMail(
        apiKey: String,
        instruction: String,
        tone: ReplyTone,
        language: AppState.ReplyLanguage,
        compact: Bool,
        completion: @escaping (Result<NewMailDraft, Error>) -> Void
    ) {
        var systemInstructions = [
            "Draft a new email for the user based only on the user's instruction.",
            "Return ONLY valid JSON with exactly these keys: subject, body.",
            "subject: write a short, useful email subject in the selected output language, ideally 2-7 words. Do not prefix it with Subject:, Betreff:, Re:, or Fwd:.",
            "body: write the actual email body only. Do not repeat the subject in the body.",
            "Be concise, natural, and appropriate for email.",
            tone.apiInstruction,
            languageInstruction(for: language, purpose: "email subject and body"),
            "Follow the user's instruction precisely.",
            "Do not invent facts, promises, dates, attachments, recipients, or commitments that the user did not provide.",
            "Do not add a signature or the user's name unless the user explicitly asks for it."
        ]
        if compact {
            systemInstructions.append("COMPACT MODE IS ON: make the body as short as possible while preserving the requested meaning. Prefer 2-4 short sentences and normally stay under 80 words.")
        }

        performRequest(
            apiKey: apiKey,
            instructions: systemInstructions.joined(separator: "\n"),
            input: "USER INSTRUCTION:\n\(instruction)",
            maxOutputTokens: compact ? 320 : 700,
            lowVerbosity: true
        ) { result in
            switch result {
            case .success(let text):
                do {
                    completion(.success(try Self.decodeNewMailDraft(text)))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private static func decodeNewMailDraft(_ text: String) throws -> NewMailDraft {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count >= 3 {
                cleaned = lines.dropFirst().dropLast().joined(separator: "\n")
                if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("json") {
                    cleaned = String(cleaned.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        guard let data = cleaned.data(using: .utf8) else {
            throw APIError(message: "OpenAI hat keinen gültigen Mailentwurf geliefert.")
        }
        do {
            let draft = try JSONDecoder().decode(NewMailDraft.self, from: data)
            guard !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw APIError(message: "OpenAI hat keinen Mailtext geliefert.")
            }
            return draft
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError(message: "OpenAI hat den Mailentwurf nicht im erwarteten Format geliefert.")
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
        let titleLanguage = language == .german ? "German" : "US English"
        let strictLanguageInstruction = language == .german
            ? "OUTPUT LANGUAGE IS GERMAN. The title and description MUST be written in German, regardless of the language used in the email thread."
            : "OUTPUT LANGUAGE IS US ENGLISH. The title and description MUST be written in natural US English, regardless of the language used in the email thread. Translate ordinary descriptive words; preserve only true proper names such as people, companies, products, and projects."

        let systemInstructions = [
            "Create a calendar event suggestion from the email thread.",
            "Return ONLY valid JSON with exactly these keys: title, description, start, end, confidence.",
            "title: the shortest useful calendar title possible, ideally 1-4 words, maximum 6 words. No filler such as Meeting, Call, Appointment, Termin unless it is necessary to understand the event.",
            "description: an extremely compact description of what the appointment is about. Prefer one short sentence or a few compact phrases, maximum 180 characters. No greeting, no sign-off, no generic filler, no repeated title. Include only information useful when opening the calendar event later.",
            strictLanguageInstruction,
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
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count >= 3 {
                cleaned = lines.dropFirst().dropLast().joined(separator: "\n")
                if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("json") {
                    cleaned = String(cleaned.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        guard let data = cleaned.data(using: .utf8) else {
            throw APIError(message: "OpenAI hat keinen gültigen Terminvorschlag geliefert.")
        }
        do {
            return try JSONDecoder().decode(CalendarSuggestion.self, from: data)
        } catch {
            throw APIError(message: "OpenAI hat den Terminvorschlag nicht im erwarteten Format geliefert.")
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
        guard let endpoint = URL(string: "https://api.openai.com/v1/files") else {
            completion(.failure(APIError(message: "Ungültige OpenAI-Datei-URL.")))
            return
        }

        let fileData: Data
        do {
            fileData = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            completion(.failure(APIError(message: "Der PDF-Anhang konnte nicht gelesen werden: \(url.lastPathComponent)")))
            return
        }

        let boundary = "Replyzen-\(UUID().uuidString)"
        let safeFilename = url.lastPathComponent.replacingOccurrences(of: "\"", with: "_")
        var body = Data()

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
                completion(.failure(APIError(message: "Keine Antwort beim PDF-Upload von OpenAI erhalten.")))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = Self.extractErrorMessage(from: data) ?? "OpenAI-PDF-Upload fehlgeschlagen (HTTP \(http.statusCode))."
                completion(.failure(APIError(message: message)))
                return
            }

            do {
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let fileID = object?["id"] as? String, !fileID.isEmpty else {
                    throw APIError(message: "OpenAI hat keine Datei-ID für den PDF-Anhang geliefert.")
                }
                completion(.success(fileID))
            } catch let error as APIError {
                completion(.failure(error))
            } catch {
                completion(.failure(APIError(message: "Die OpenAI-Antwort auf den PDF-Upload war ungültig.")))
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
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count >= 3 {
                cleaned = lines.dropFirst().dropLast().joined(separator: "\n")
                if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("json") {
                    cleaned = String(cleaned.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        guard let data = cleaned.data(using: .utf8) else {
            throw APIError(message: "OpenAI hat keine gültigen Überweisungsdaten geliefert.")
        }
        do {
            return try JSONDecoder().decode(PaymentSuggestion.self, from: data)
        } catch {
            throw APIError(message: "OpenAI hat die Überweisungsdaten nicht im erwarteten Format geliefert.")
        }
    }

    private func languageInstruction(for language: AppState.ReplyLanguage, purpose: String) -> String {
        switch language {
        case .german:
            return "Write the entire \(purpose) in natural German. Do not switch to English unless the user explicitly asks for it."
        case .usEnglish:
            return "Write the entire \(purpose) in natural US English. Use American spelling and phrasing. Do not switch to German unless the user explicitly asks for it."
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
            completion(.failure(APIError(message: "Ungültige OpenAI-URL.")))
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
                completion(.failure(APIError(message: "Keine Antwort von OpenAI erhalten.")))
                return
            }

            guard (200..<300).contains(http.statusCode) else {
                let message = Self.extractErrorMessage(from: data) ?? "OpenAI-Fehler HTTP \(http.statusCode)."
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
            throw APIError(message: "OpenAI hat ein unerwartetes Antwortformat geliefert.")
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
            throw APIError(message: "OpenAI hat keinen Antworttext geliefert.")
        }
        return result
    }
}
