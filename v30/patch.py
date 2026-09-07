from pathlib import Path
import re
import sys

root = Path(sys.argv[1])


def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f'{label} not found')
    return text.replace(old, new, 1)


# 1) AppState: make payment a real fourth mode so all main functions can share
# the same UI and behavior.
p = root / 'app' / 'AppState.swift'
s = p.read_text()
s = must_replace(
    s,
    '        case calendar\n\n        var id: String { rawValue }',
    '        case calendar\n        case payment\n\n        var id: String { rawValue }',
    'AppState OutputMode cases'
)
s = must_replace(
    s,
    '            case .calendar: return "Termin"\n',
    '            case .calendar: return "Termin"\n            case .payment: return "Überweisung"\n',
    'AppState payment display name'
)
p.write_text(s)


# 2) AttachmentTextExtractor: expose resolved local attachment URLs. PDFs are
# not OCRed locally in the normal payment flow anymore; they are passed to
# OpenAI as real files so layout, tables and scanned PDF pages can be read.
p = root / 'app' / 'AttachmentTextExtractor.swift'
s = p.read_text()
anchor = '    func extract(filenames: [String]) -> Result {\n'
if anchor not in s:
    raise SystemExit('AttachmentTextExtractor extract anchor not found')
resolver = '''    func resolveFiles(filenames: [String]) -> [URL] {\n        var result: [URL] = []\n        var seen = Set<String>()\n\n        for filename in filenames.prefix(6) {\n            guard let url = findFile(named: filename) else { continue }\n            let key = url.standardizedFileURL.path.lowercased()\n            if seen.insert(key).inserted {\n                result.append(url)\n            }\n        }\n        return result\n    }\n\n'''
s = s.replace(anchor, resolver + anchor, 1)
p.write_text(s)


# 3) Overlay: replace segmented modes + separate payment action with four
# equal icon buttons. Payment is now a normal mode with its own primary action.
p = root / 'app' / 'OverlayView.swift'
s = p.read_text()

start = s.index('            Picker("Modus", selection: $state.outputMode) {')
end = s.index('            if state.outputMode != .newMail {', start)
s = s[:start] + '            modeSelector\n\n' + s[end:]

# Payment-specific content panel.
old_calendar_boundary = '''                .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))\n            } else {\n                Text(state.outputMode == .reply ? "Was soll ich antworten?" : "Was soll ich schreiben?")\n'''
new_calendar_boundary = '''                .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))\n            } else if state.outputMode == .payment {\n                VStack(alignment: .leading, spacing: 8) {\n                    HStack(spacing: 8) {\n                        Image(systemName: "banknote")\n                            .font(.title2)\n                        Text("Überweisung aus Mail + PDF")\n                            .font(.title3.bold())\n                    }\n                    Text("Replyzen liest den PDF-Anhang standardmäßig direkt mit OpenAI und extrahiert daraus Empfänger, IBAN, BIC, Betrag, Währung und Verwendungszweck. Der Mailtext dient nur als zusätzlicher Kontext.")\n                        .foregroundStyle(.secondary)\n                }\n                .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)\n                .padding(14)\n                .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))\n            } else {\n                Text(state.outputMode == .reply ? "Was soll ich antworten?" : "Was soll ich schreiben?")\n'''
s = must_replace(s, old_calendar_boundary, new_calendar_boundary, 'payment mode content block')

# Hide language buttons for payment, where they are irrelevant.
old_languages = '''                languageButton("🇩🇪", language: .german, help: "Ausgabe auf Deutsch")\n                languageButton("🇺🇸", language: .usEnglish, help: "Ausgabe in US English")\n'''
new_languages = '''                if state.outputMode != .payment {\n                    languageButton("🇩🇪", language: .german, help: "Ausgabe auf Deutsch")\n                    languageButton("🇺🇸", language: .usEnglish, help: "Ausgabe in US English")\n                }\n'''
s = must_replace(s, old_languages, new_languages, 'language buttons')

# Status line: payment shows the source behavior instead of a language label.
old_status_tail = '''            } else {\n                Text("Sprache: \\(state.replyLanguage.displayName)")\n                    .font(.caption)\n                    .foregroundStyle(.secondary)\n            }\n\n            HStack {\n'''
new_status_tail = '''            } else if state.outputMode == .calendar {\n                Text("Sprache: \\(state.replyLanguage.displayName)")\n                    .font(.caption)\n                    .foregroundStyle(.secondary)\n            } else {\n                HStack(spacing: 6) {\n                    Image(systemName: "doc.richtext")\n                    Text("PDF wird direkt von OpenAI gelesen")\n                }\n                .font(.caption)\n                .foregroundStyle(.secondary)\n            }\n\n            HStack {\n'''
s = must_replace(s, old_status_tail, new_status_tail, 'payment status line')

# Add the uniform mode buttons before the mail context banner.
mode_helper_anchor = '    @ViewBuilder\n    private var mailContextBanner: some View {\n'
if mode_helper_anchor not in s:
    raise SystemExit('mailContextBanner anchor not found')
mode_helper = '''    private var modeSelector: some View {\n        HStack(spacing: 8) {\n            modeButton(.reply, title: "Reply", systemImage: "arrowshape.turn.up.left.fill")\n            modeButton(.newMail, title: "New Mail", systemImage: "square.and.pencil")\n            modeButton(.calendar, title: "Termin", systemImage: "calendar.badge.plus")\n            modeButton(.payment, title: "Überweisung", systemImage: "banknote")\n        }\n    }\n\n    private func modeButton(_ mode: AppState.OutputMode, title: String, systemImage: String) -> some View {\n        Button {\n            guard state.outputMode != mode else { return }\n            state.outputMode = mode\n            handleModeChange(mode)\n        } label: {\n            HStack(spacing: 7) {\n                Image(systemName: systemImage)\n                    .font(.system(size: 14, weight: .semibold))\n                Text(title)\n                    .font(.system(size: 14, weight: .semibold))\n                    .lineLimit(1)\n            }\n            .frame(maxWidth: .infinity, minHeight: 34)\n        }\n        .buttonStyle(.borderedProminent)\n        .tint(state.outputMode == mode ? .accentColor : .gray.opacity(0.32))\n        .controlSize(.regular)\n    }\n\n'''
s = s.replace(mode_helper_anchor, mode_helper + mode_helper_anchor, 1)

# Exhaustive mode switches.
s = must_replace(
    s,
    '        case .calendar: return "Ich erstelle einen kurzen Termintitel und erkenne den Zeitpunkt …"\n        }\n',
    '        case .calendar: return "Ich erstelle einen kurzen Termintitel und erkenne den Zeitpunkt …"\n        case .payment: return "Ich lese den PDF-Anhang und extrahiere die Überweisungsdaten …"\n        }\n',
    'generatingSubtitle payment'
)
s = must_replace(
    s,
    '        case .calendar: return "Termin erstellen"\n        }\n',
    '        case .calendar: return "Termin erstellen"\n        case .payment: return "Überweisung extrahieren"\n        }\n',
    'primary action title payment'
)
s = must_replace(
    s,
    '        case .calendar:\n            return !mailAvailable\n        }\n',
    '        case .calendar, .payment:\n            return !mailAvailable\n        }\n',
    'primary disabled payment'
)
s = must_replace(
    s,
    '        case .calendar:\n            break\n        }\n    }\n\n    private func applyCommand',
    '        case .calendar, .payment:\n            break\n        }\n    }\n\n    private func applyCommand',
    'handleModeChange payment'
)
s = must_replace(
    s,
    '        case .calendar: return "Termin"\n        }\n',
    '        case .calendar: return "Termin"\n        case .payment: return "Überweisung"\n        }\n',
    'previewTitle payment'
)
p.write_text(s)


# 4) Floating panel: sensible preferred size for the fourth mode.
p = root / 'app' / 'FloatingPanelController.swift'
s = p.read_text()
s = must_replace(
    s,
    '            case .calendar:\n                return NSSize(width: 840, height: 640)\n            }\n',
    '            case .calendar, .payment:\n                return NSSize(width: 840, height: 640)\n            }\n',
    'FloatingPanel payment mode size'
)
p.write_text(s)


# 5) AppDelegate: route payment through the same primary mode flow and pass
# actual PDF files to OpenAI. Local OCR/text extraction is retained only as a
# fallback if no PDF file can be resolved.
p = root / 'app' / 'AppDelegate.swift'
s = p.read_text()
s = must_replace(
    s,
    '        case .calendar:\n            generateCalendarSuggestion()\n        }\n',
    '        case .calendar:\n            generateCalendarSuggestion()\n        case .payment:\n            generatePaymentSuggestion()\n        }\n',
    'AppDelegate generateCurrentOutput payment'
)
s = must_replace(
    s,
    '        case .calendar:\n            break\n        }\n    }\n\n    private func insertReply()',
    '        case .calendar, .payment:\n            break\n        }\n    }\n\n    private func insertReply()',
    'AppDelegate insertGeneratedText payment'
)

pay_start = s.index('    private func generatePaymentSuggestion() {')
pay_end = s.index('    private func copyPaymentDetails()', pay_start)
new_payment = '''    private func generatePaymentSuggestion() {\n        guard let apiKey = keychain.loadAPIKey() else {\n            state.stage = .apiKey\n            return\n        }\n        guard !state.mailText.isEmpty, let snapshot = activeSnapshot else {\n            state.mailStatus = .unavailable("Keine lesbare Outlook-Mail erkannt. Für eine Überweisung bitte die Rechnungsmail öffnen und erneut versuchen.")\n            return\n        }\n\n        isRunningFlow = true\n        toolbarButton.setSuppressed(true)\n        state.stage = .generating\n        state.statusText = "Replyzen sucht den PDF-Anhang …"\n\n        DispatchQueue.global(qos: .userInitiated).async { [weak self] in\n            guard let self else { return }\n\n            let filenames = self.outlook.attachmentFilenames(from: snapshot)\n            let resolvedFiles = self.attachmentExtractor.resolveFiles(filenames: filenames)\n            let pdfFiles = resolvedFiles.filter { $0.pathExtension.lowercased() == "pdf" }\n            let selectedPDFs = Array(pdfFiles.prefix(3))\n\n            var fallbackText = ""\n            var sourceStatus: String\n\n            if !selectedPDFs.isEmpty {\n                sourceStatus = "PDF direkt mit OpenAI gelesen: " + selectedPDFs.map(\\.lastPathComponent).joined(separator: ", ")\n                DispatchQueue.main.async {\n                    self.state.statusText = "PDF wird direkt an OpenAI übergeben und gelesen …"\n                }\n            } else {\n                let fallback = self.attachmentExtractor.extract(filenames: filenames)\n                fallbackText = fallback.text\n\n                let pdfMentioned = filenames.contains { $0.lowercased().hasSuffix(".pdf") }\n                if !fallback.usedFiles.isEmpty {\n                    sourceStatus = "Kein direkt zugängliches PDF; lokal gelesen: " + fallback.usedFiles.joined(separator: ", ")\n                } else if pdfMentioned {\n                    sourceStatus = "PDF-Anhang in Outlook erkannt, aber die lokale PDF-Datei war nicht zugänglich. Extraktion nur aus dem Mailtext."\n                } else {\n                    sourceStatus = "Kein PDF-Anhang erkannt. Extraktion aus dem Mailtext."\n                }\n                DispatchQueue.main.async {\n                    self.state.statusText = sourceStatus\n                }\n            }\n\n            self.openAI.createPaymentSuggestion(\n                apiKey: apiKey,\n                mailText: self.state.mailText,\n                fileURLs: selectedPDFs,\n                fallbackAttachmentText: fallbackText\n            ) { [weak self] result in\n                DispatchQueue.main.async {\n                    guard let self else { return }\n                    self.isRunningFlow = false\n\n                    switch result {\n                    case .success(let suggestion):\n                        self.state.paymentRecipient = suggestion.recipient?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""\n                        self.state.paymentIBAN = suggestion.iban?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""\n                        self.state.paymentBIC = suggestion.bic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""\n                        self.state.paymentAmount = suggestion.amount?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""\n                        self.state.paymentCurrency = suggestion.currency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "EUR"\n                        self.state.paymentPurpose = suggestion.purpose?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""\n                        self.state.paymentSourceStatus = sourceStatus\n\n                        let confidence = suggestion.confidence?.lowercased() ?? "low"\n                        let missingCore = self.state.paymentRecipient.isEmpty || self.state.paymentIBAN.isEmpty || self.state.paymentAmount.isEmpty\n                        if selectedPDFs.isEmpty {\n                            self.state.paymentWarning = "Kein PDF wurde direkt von OpenAI gelesen. Bitte Empfänger, IBAN und Betrag besonders sorgfältig prüfen."\n                        } else if confidence == "low" || missingCore {\n                            self.state.paymentWarning = "Die Extraktion ist nicht eindeutig. Bitte die PDF-Rechnung mit den Feldern unten vergleichen."\n                        } else {\n                            self.state.paymentWarning = "Bitte IBAN, Betrag und Verwendungszweck vor einer Überweisung immer mit der PDF-Rechnung vergleichen."\n                        }\n\n                        self.state.stage = .paymentPreview\n                        self.panel.show()\n                    case .failure(let error):\n                        self.showError(error.localizedDescription)\n                    }\n                }\n            }\n        }\n    }\n\n'''
s = s[:pay_start] + new_payment + s[pay_end:]
p.write_text(s)


# 6) OpenAIClient: use the current speed-oriented GPT-5.6 Luna model across
# Replyzen, with reasoning disabled. Payment extraction uploads PDFs to the
# Files API and supplies them as input_file items to the Responses API.
p = root / 'app' / 'OpenAIClient.swift'
s = p.read_text()

# All explicit old fast models become Luna.
s = s.replace('model: "gpt-5.4-nano"', 'model: "gpt-5.6-luna"')
s = s.replace('model: String = "gpt-5.4-mini"', 'model: String = "gpt-5.6-luna"')
# Existing String inputs continue to work, but file-aware requests need an
# array/object payload.
s = must_replace(s, '        input: String,\n', '        input: Any,\n', 'performRequest Any input')

payment_start = s.index('    func createPaymentSuggestion(')
payment_end = s.index('    private static func decodePaymentSuggestion', payment_start)
new_payment_client = r'''    func createPaymentSuggestion(
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

'''
s = s[:payment_start] + new_payment_client + s[payment_end:]

# Keep ordinary responses short and fast as well.
s = s.replace(
    '            input: "USER INSTRUCTION:\\n\\(instruction)\\n\\nEMAIL CONTENT:\\n\\(String(mailText.prefix(30_000)))",\n            completion: completion\n',
    '            input: "USER INSTRUCTION:\\n\\(instruction)\\n\\nEMAIL CONTENT:\\n\\(String(mailText.prefix(30_000)))",\n            maxOutputTokens: 520,\n            lowVerbosity: true,\n            completion: completion\n',
    1
)
s = s.replace('            lowVerbosity: compact\n', '            lowVerbosity: true\n', 1)
p.write_text(s)


# 7) Version bump and package metadata.
p = root / 'app' / 'Info.plist'
s = p.read_text()
s = must_replace(s, '<string>1.19.0</string>', '<string>1.20.0</string>', 'version 1.20')
s = must_replace(s, '<string>20</string>', '<string>21</string>', 'build 21')
p.write_text(s)

p = root / 'Build-CI.sh'
s = p.read_text()
s = s.replace('Replyzen-update-1.19.zip', 'Replyzen-update-1.20.zip')
s = s.replace(
    'Replyzen 1.19: cache-sicherer Updater mit zweiter GitHub-API-Quelle und frischer URLSession; alte manuelle Cache-URLs werden automatisch bereinigt.',
    'Replyzen 1.20: vier einheitliche Funktionsbuttons; GPT-5.6 Luna ohne Reasoning für schnelle Antworten; Überweisung liest PDF-Rechnungen direkt mit OpenAI und löscht temporär hochgeladene Dateien nach der Extraktion.'
)
p.write_text(s)
