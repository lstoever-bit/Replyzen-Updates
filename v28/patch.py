from pathlib import Path
import sys

root = Path(sys.argv[1])


def replace_once(path, old, new, label):
    p = root / path
    s = p.read_text()
    if old not in s:
        raise SystemExit(f'{label} not found in {path}')
    p.write_text(s.replace(old, new, 1))

# AppState: add payment preview state and actions.
p = root / 'app' / 'AppState.swift'
s = p.read_text()
s = s.replace('''        case calendarPreview\n        case inserting''', '''        case calendarPreview\n        case paymentPreview\n        case inserting''', 1)
s = s.replace('''    @Published var successMessage: String = ""\n\n    var mailText: String = ""''', '''    @Published var successMessage: String = ""\n    @Published var paymentRecipient: String = ""\n    @Published var paymentIBAN: String = ""\n    @Published var paymentBIC: String = ""\n    @Published var paymentAmount: String = ""\n    @Published var paymentCurrency: String = "EUR"\n    @Published var paymentPurpose: String = ""\n    @Published var paymentSourceStatus: String = ""\n    @Published var paymentWarning: String = ""\n\n    var mailText: String = ""''', 1)
s = s.replace('''    var createCalendarAction: (() -> Void)?\n    var connectGoogleCalendarAction: (() -> Void)?''', '''    var createCalendarAction: (() -> Void)?\n    var extractPaymentAction: (() -> Void)?\n    var copyPaymentAction: (() -> Void)?\n    var connectGoogleCalendarAction: (() -> Void)?''', 1)
p.write_text(s)

# Keyboard: Tab fallback for Outlook compose body.
p = root / 'app' / 'KeyboardController.swift'
s = p.read_text()
s = s.replace('''    func sendCommandV() {\n        sendKey(code: 9, flags: .maskCommand)\n    }''', '''    func sendCommandV() {\n        sendKey(code: 9, flags: .maskCommand)\n    }\n\n    func sendTab() {\n        sendKey(code: 48, flags: [])\n    }''', 1)
p.write_text(s)

# OpenAI: fast mini model with no reasoning for normal drafting; add payment extraction on nano.
p = root / 'app' / 'OpenAIClient.swift'
s = p.read_text()
s = s.replace('''        model: String = "gpt-5-mini",\n        reasoningEffort: String? = nil,''', '''        model: String = "gpt-5.4-mini",\n        reasoningEffort: String? = "none",''', 1)

payment_code = r'''
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
        attachmentText: String,
        completion: @escaping (Result<PaymentSuggestion, Error>) -> Void
    ) {
        let systemInstructions = [
            "Extract bank transfer details from the supplied email and readable attachment text.",
            "Return ONLY valid JSON with exactly these keys: recipient, iban, bic, amount, currency, purpose, confidence.",
            "Never invent or guess banking details. If a field is not clearly supported, return null for that field.",
            "recipient: exact payee/account holder name if stated.",
            "iban: exact IBAN, preferably without spaces. Preserve every character accurately.",
            "bic: exact BIC/SWIFT if stated, otherwise null.",
            "amount: exact payment amount using digits and decimal separator only, without currency symbol.",
            "currency: ISO currency code such as EUR only when supported by the source.",
            "purpose: the shortest useful payment reference, prioritizing invoice number, customer number, reference number, or explicitly requested Verwendungszweck.",
            "confidence must be one of high, medium, low.",
            "If email and attachment conflict on IBAN, recipient, or amount, set the conflicting field to null and confidence to low.",
            "This is extraction only; do not suggest or initiate a payment."
        ].joined(separator: "\n")

        let input = "EMAIL:\n\(String(mailText.prefix(24_000)))\n\nREADABLE ATTACHMENT TEXT:\n\(String(attachmentText.prefix(24_000)))"
        performRequest(
            apiKey: apiKey,
            instructions: systemInstructions,
            input: input,
            model: "gpt-5.4-nano",
            reasoningEffort: "none",
            maxOutputTokens: 280,
            lowVerbosity: true
        ) { result in
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

'''
anchor = '    private func languageInstruction(for language: AppState.ReplyLanguage, purpose: String) -> String {'
if anchor not in s:
    raise SystemExit('OpenAI payment insertion anchor not found')
s = s.replace(anchor, payment_code + anchor, 1)
p.write_text(s)

# Outlook Accessibility: discover attachment filenames visible in the current Outlook message.
p = root / 'app' / 'OutlookAccessibility.swift'
s = p.read_text()
anchor = '    func runningPID() -> pid_t? {'
attachment_method = r'''
    func attachmentFilenames(from snapshot: Snapshot) -> [String] {
        let pattern = #"(?i)([^/\\\n\r\t<>:\"|?*]{1,180}\.(?:pdf|png|jpe?g|tiff?))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let attributes: [CFString] = [
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString,
            kAXValueAttribute as CFString,
            "AXFilename" as CFString,
            "AXURL" as CFString
        ]
        var names: [String] = []
        var seen = Set<String>()

        for window in snapshot.windows {
            var stack: [AXUIElement] = [window]
            var visited = 0
            while let element = stack.popLast(), visited < 18_000 {
                visited += 1
                for attribute in attributes {
                    guard let raw = stringLikeAttribute(attribute, from: element), !raw.isEmpty else { continue }
                    let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
                    for match in regex.matches(in: raw, range: range) {
                        guard match.numberOfRanges > 1,
                              let matchRange = Range(match.range(at: 1), in: raw) else { continue }
                        let name = String(raw[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let key = name.lowercased()
                        if !name.isEmpty && !seen.contains(key) {
                            seen.insert(key)
                            names.append(name)
                        }
                    }
                }
                for child in children(of: element).reversed() { stack.append(child) }
            }
        }
        return Array(names.prefix(6))
    }

'''
if anchor not in s:
    raise SystemExit('Outlook attachment anchor not found')
s = s.replace(anchor, attachment_method + anchor, 1)
helper_anchor = '    private func pointAttribute(_ attribute: CFString, from element: AXUIElement) -> CGPoint? {'
helper = r'''
    private func stringLikeAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success, let value else { return nil }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        if let url = value as? NSURL { return url.absoluteString }
        return nil
    }

'''
if helper_anchor not in s:
    raise SystemExit('Outlook stringLike helper anchor not found')
s = s.replace(helper_anchor, helper + helper_anchor, 1)
p.write_text(s)

# New local best-effort attachment text reader: PDFKit + Vision OCR, looking up exact filenames in Outlook caches/Spotlight.
attachment_file = root / 'app' / 'AttachmentTextExtractor.swift'
attachment_file.write_text(r'''import Foundation
import AppKit
import PDFKit
import Vision

final class AttachmentTextExtractor {
    struct Result {
        let text: String
        let usedFiles: [String]
    }

    func extract(filenames: [String]) -> Result {
        var chunks: [String] = []
        var used: [String] = []

        for filename in filenames.prefix(4) {
            guard let url = findFile(named: filename) else { continue }
            let ext = url.pathExtension.lowercased()
            let text: String
            if ext == "pdf" {
                text = extractPDF(url)
            } else if ["png", "jpg", "jpeg", "tif", "tiff"].contains(ext) {
                text = extractImage(url)
            } else {
                text = ""
            }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                used.append(url.lastPathComponent)
                chunks.append("ATTACHMENT \(url.lastPathComponent):\n\(String(cleaned.prefix(18_000)))")
            }
        }

        return Result(text: String(chunks.joined(separator: "\n\n").prefix(30_000)), usedFiles: used)
    }

    private func findFile(named filename: String) -> URL? {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: filename).lastPathComponent
        guard !base.isEmpty else { return nil }

        // Spotlight is much faster than walking the full Outlook profile when the file is indexed.
        if let path = spotlightPath(named: base), fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let home = fm.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent("Library/Containers/com.microsoft.Outlook/Data/Library/Caches", isDirectory: true),
            home.appendingPathComponent("Library/Group Containers/UBF8T346G9.Office/Outlook", isDirectory: true),
            home.appendingPathComponent("Library/Caches/com.microsoft.Outlook", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        ]

        var best: (URL, Date)?
        var visited = 0
        for root in roots where fm.fileExists(atPath: root.path) {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                visited += 1
                if visited > 80_000 { break }
                guard url.lastPathComponent.caseInsensitiveCompare(base) == .orderedSame else { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                let date = values?.contentModificationDate ?? .distantPast
                if best == nil || date > best!.1 { best = (url, date) }
            }
            if visited > 80_000 { break }
        }
        return best?.0
    }

    private func spotlightPath(named filename: String) -> String? {
        let escaped = filename.replacingOccurrences(of: "'", with: "\\'")
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["kMDItemFSName == '\(escaped)'c"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let candidates = output.split(separator: "\n").map(String.init)
            return candidates.first { path in
                let lower = path.lowercased()
                return lower.contains("outlook") || lower.contains("downloads") || lower.contains("temporary") || lower.contains("/var/folders/")
            } ?? candidates.first
        } catch {
            return nil
        }
    }

    private func extractPDF(_ url: URL) -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        var pieces: [String] = []
        for index in 0..<min(document.pageCount, 12) {
            if let text = document.page(at: index)?.string, !text.isEmpty {
                pieces.append(text)
            }
        }
        return pieces.joined(separator: "\n")
    }

    private func extractImage(_ url: URL) -> String {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["de-DE", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        } catch {
            return ""
        }
    }
}
''')

# AppDelegate: wire payment flow and make New Mail body insertion robust via Subject -> Tab -> paste.
p = root / 'app' / 'AppDelegate.swift'
s = p.read_text()
s = s.replace('''    private let calendarManager = CalendarManager()\n    private lazy var toolbarButton''', '''    private let calendarManager = CalendarManager()\n    private let attachmentExtractor = AttachmentTextExtractor()\n    private lazy var toolbarButton''', 1)
s = s.replace('''        state.createCalendarAction = { [weak self] in self?.createCalendarEvent() }\n        state.connectGoogleCalendarAction''', '''        state.createCalendarAction = { [weak self] in self?.createCalendarEvent() }\n        state.extractPaymentAction = { [weak self] in self?.generatePaymentSuggestion() }\n        state.copyPaymentAction = { [weak self] in self?.copyPaymentDetails() }\n        state.connectGoogleCalendarAction''', 1)

# Insert payment methods before createCalendarEvent.
anchor = '    private func createCalendarEvent() {'
payment_methods = r'''
    private func generatePaymentSuggestion() {
        guard let apiKey = keychain.loadAPIKey() else {
            state.stage = .apiKey
            return
        }
        guard !state.mailText.isEmpty, let snapshot = activeSnapshot else {
            state.mailStatus = .unavailable("Keine lesbare Outlook-Mail erkannt. Für Überweisungsdaten bitte eine Mail öffnen und erneut versuchen.")
            return
        }

        isRunningFlow = true
        toolbarButton.setSuppressed(true)
        state.stage = .generating
        state.statusText = "Replyzen liest Mail und versucht PDF/Bild-Anhänge lokal auszulesen"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let filenames = self.outlook.attachmentFilenames(from: snapshot)
            let attachment = self.attachmentExtractor.extract(filenames: filenames)
            let sourceStatus: String
            if !attachment.usedFiles.isEmpty {
                sourceStatus = "Anhang gelesen: " + attachment.usedFiles.joined(separator: ", ")
            } else if filenames.isEmpty {
                sourceStatus = "Kein lesbarer PDF/Bild-Anhang erkannt – Extraktion aus dem Mailtext."
            } else {
                sourceStatus = "Anhang erkannt, aber nicht automatisch lesbar – Extraktion aus dem Mailtext."
            }

            self.openAI.createPaymentSuggestion(
                apiKey: apiKey,
                mailText: self.state.mailText,
                attachmentText: attachment.text
            ) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRunningFlow = false
                    switch result {
                    case .success(let suggestion):
                        self.state.paymentRecipient = suggestion.recipient ?? ""
                        self.state.paymentIBAN = (suggestion.iban ?? "").replacingOccurrences(of: " ", with: "").uppercased()
                        self.state.paymentBIC = (suggestion.bic ?? "").replacingOccurrences(of: " ", with: "").uppercased()
                        self.state.paymentAmount = suggestion.amount ?? ""
                        self.state.paymentCurrency = (suggestion.currency ?? "EUR").uppercased()
                        self.state.paymentPurpose = suggestion.purpose ?? ""
                        self.state.paymentSourceStatus = sourceStatus
                        self.state.paymentWarning = "Bitte Empfänger, IBAN, Betrag und Verwendungszweck vor jeder Überweisung prüfen. Replyzen führt keine Zahlung aus."
                        if suggestion.confidence == "low" {
                            self.state.paymentWarning = "Unsichere oder widersprüchliche Daten erkannt. Bitte alle Felder besonders sorgfältig prüfen. Replyzen führt keine Zahlung aus."
                        }
                        self.state.stage = .paymentPreview
                        self.panel.show()
                    case .failure(let error):
                        self.showError(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func copyPaymentDetails() {
        let lines = [
            state.paymentRecipient.isEmpty ? nil : "Empfänger: \(state.paymentRecipient)",
            state.paymentIBAN.isEmpty ? nil : "IBAN: \(state.paymentIBAN)",
            state.paymentBIC.isEmpty ? nil : "BIC: \(state.paymentBIC)",
            state.paymentAmount.isEmpty ? nil : "Betrag: \(state.paymentAmount) \(state.paymentCurrency)",
            state.paymentPurpose.isEmpty ? nil : "Verwendungszweck: \(state.paymentPurpose)"
        ].compactMap { $0 }
        guard !lines.isEmpty else { return }
        copyToPasteboard(lines.joined(separator: "\n"))
        state.successMessage = "Überweisungsdaten wurden in die Zwischenablage kopiert. Bitte vor der Zahlung im Banking prüfen."
        state.stage = .success
        panel.show()
    }

'''
if anchor not in s:
    raise SystemExit('AppDelegate payment anchor not found')
s = s.replace(anchor, payment_methods + anchor, 1)

old_populate = r'''    private func populateNewMailDraft(subject: String, body: String, attempt: Int) {
        let delay = attempt == 0 ? 0.85 : 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }

            let subjectDone = subject.isEmpty || self.outlook.setComposeSubjectValue(subject)
            let bodyDone = self.outlook.setComposeBodyValue(body)

            if subjectDone && bodyDone {
                self.finishNewMailInsertion()
                return
            }

            if attempt < 8 {
                self.populateNewMailDraft(subject: subject, body: body, attempt: attempt + 1)
                return
            }

            // Fallback for Outlook builds where the web editor is focusable but AXValue is not directly settable.
            var subjectReady = subjectDone
            if !subjectReady, self.outlook.focusComposeSubjectField() {
                self.copyToPasteboard(subject)
                self.keyboard.sendCommandV()
                subjectReady = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self else { return }
                if self.outlook.focusComposeBodyField() {
                    self.copyToPasteboard(body)
                    self.keyboard.sendCommandV()
                    self.finishNewMailInsertion()
                } else {
                    self.copyToPasteboard(body)
                    self.isRunningFlow = false
                    let subjectInfo = subjectReady ? "Der Betreff wurde eingesetzt. " : ""
                    self.showError("\(subjectInfo)Der Outlook-Mailtext konnte nicht automatisch fokussiert werden. Der Mailtext liegt in der Zwischenablage.")
                }
            }
        }
    }
'''
new_populate = r'''    private func populateNewMailDraft(subject: String, body: String, attempt: Int) {
        let delay = attempt == 0 ? 0.8 : 0.22
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }

            let subjectDone = subject.isEmpty || self.outlook.setComposeSubjectValue(subject)
            if self.outlook.setComposeBodyValue(body) {
                self.finishNewMailInsertion()
                return
            }

            // Give Outlook a short moment to finish constructing the compose window, but do not wait for many retries.
            if attempt < 2 {
                self.populateNewMailDraft(subject: subject, body: body, attempt: attempt + 1)
                return
            }

            var subjectReady = subjectDone
            if !subjectReady, self.outlook.focusComposeSubjectField() {
                self.copyToPasteboard(subject)
                self.keyboard.sendCommandV()
                subjectReady = true
            }

            // Classic Outlook exposes the subject reliably but often does not expose the HTML body as a settable AXTextArea.
            // From the subject field, one Tab moves the caret into the message body much more reliably.
            if subjectReady, self.outlook.focusComposeSubjectField() {
                self.keyboard.sendTab()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                    guard let self else { return }
                    self.copyToPasteboard(body)
                    self.keyboard.sendCommandV()
                    self.finishNewMailInsertion()
                }
                return
            }

            if self.outlook.focusComposeBodyField() {
                self.copyToPasteboard(body)
                self.keyboard.sendCommandV()
                self.finishNewMailInsertion()
            } else {
                self.copyToPasteboard(body)
                self.isRunningFlow = false
                self.showError("Der Mailtext konnte nicht automatisch eingesetzt werden. Er liegt in der Zwischenablage.")
            }
        }
    }
'''
if old_populate not in s:
    raise SystemExit('populateNewMailDraft block not found')
s = s.replace(old_populate, new_populate, 1)
p.write_text(s)

# Overlay UI: add transfer extraction button and editable preview.
p = root / 'app' / 'OverlayView.swift'
s = p.read_text()
s = s.replace('''        case .calendarPreview:\n            ScrollView {\n                calendarPreviewView\n                    .frame(maxWidth: .infinity, alignment: .leading)\n            }\n        case .inserting:''', '''        case .calendarPreview:\n            ScrollView {\n                calendarPreviewView\n                    .frame(maxWidth: .infinity, alignment: .leading)\n            }\n        case .paymentPreview:\n            ScrollView {\n                paymentPreviewView\n                    .frame(maxWidth: .infinity, alignment: .leading)\n            }\n        case .inserting:''', 1)
s = s.replace('''            Text("Reply, New Mail oder Termin – direkt aus Outlook.")''', '''            Text("Reply, New Mail, Termin oder Überweisung – direkt aus Outlook.")''', 1)

# Add payment button below segmented mode picker.
mode_anchor = '''            .onChange(of: state.outputMode) { mode in\n                handleModeChange(mode)\n            }\n\n            if state.outputMode != .newMail {'''
mode_new = '''            .onChange(of: state.outputMode) { mode in\n                handleModeChange(mode)\n            }\n\n            HStack {\n                Spacer()\n                Button {\n                    state.extractPaymentAction?()\n                } label: {\n                    Label("Überweisung aus Mail + Anhang", systemImage: "banknote")\n                }\n                .controlSize(.small)\n                .disabled(!mailAvailable)\n                .help("Versucht Empfänger, IBAN, Betrag und Verwendungszweck aus Mail und lesbarem PDF/Bild-Anhang zu extrahieren")\n            }\n\n            if state.outputMode != .newMail {'''
if mode_anchor not in s:
    raise SystemExit('Overlay mode anchor not found')
s = s.replace(mode_anchor, mode_new, 1)

# Insert payment preview before calendar preview.
calendar_anchor = '    private var calendarPreviewView: some View {'
payment_view = r'''
    private var paymentPreviewView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "banknote")
                    .font(.title2)
                Text("Überweisung prüfen")
                    .font(.title2.bold())
            }

            if !state.paymentWarning.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(state.paymentWarning)
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
                .padding(10)
                .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Empfänger").font(.caption).foregroundStyle(.secondary)
                TextField("Empfänger", text: $state.paymentRecipient)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("IBAN").font(.caption).foregroundStyle(.secondary)
                TextField("IBAN", text: $state.paymentIBAN)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Betrag").font(.caption).foregroundStyle(.secondary)
                    TextField("0,00", text: $state.paymentAmount)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Währung").font(.caption).foregroundStyle(.secondary)
                    TextField("EUR", text: $state.paymentCurrency)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("BIC (optional)").font(.caption).foregroundStyle(.secondary)
                    TextField("BIC", text: $state.paymentBIC)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Verwendungszweck").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $state.paymentPurpose)
                    .font(.body)
                    .frame(height: 70)
                    .padding(6)
                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            }

            if !state.paymentSourceStatus.isEmpty {
                Text(state.paymentSourceStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Zurück") { state.stage = .instruction }
                Spacer()
                Button("Überweisungsdaten kopieren") { state.copyPaymentAction?() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.paymentRecipient.isEmpty && state.paymentIBAN.isEmpty && state.paymentAmount.isEmpty)
            }
        }
    }

'''
if calendar_anchor not in s:
    raise SystemExit('Overlay payment preview anchor not found')
s = s.replace(calendar_anchor, payment_view + calendar_anchor, 1)
p.write_text(s)

# Floating panel: payment preview size.
p = root / 'app' / 'FloatingPanelController.swift'
s = p.read_text()
s = s.replace('''        case .calendarPreview:\n            let extraOAuthHeight = state.googleNeedsOAuthCredentials ? 130.0 : 0.0\n            let warningHeight = state.calendarWarning.isEmpty ? 0.0 : 50.0\n            return NSSize(width: 880, height: 760 + extraOAuthHeight + warningHeight)\n        case .preview:''', '''        case .calendarPreview:\n            let extraOAuthHeight = state.googleNeedsOAuthCredentials ? 130.0 : 0.0\n            let warningHeight = state.calendarWarning.isEmpty ? 0.0 : 50.0\n            return NSSize(width: 880, height: 760 + extraOAuthHeight + warningHeight)\n        case .paymentPreview:\n            return NSSize(width: 840, height: 690)\n        case .preview:''', 1)
p.write_text(s)

# Build frameworks + version/package metadata.
p = root / 'app' / 'Info.plist'
s = p.read_text()
s = s.replace('<string>1.17.0</string>', '<string>1.18.0</string>', 1)
s = s.replace('<string>18</string>', '<string>19</string>', 1)
p.write_text(s)

p = root / 'Build-CI.sh'
s = p.read_text()
s = s.replace('Replyzen-update-1.17.zip', 'Replyzen-update-1.18.zip')
s = s.replace('-framework Security -framework ServiceManagement -framework Network \\', '-framework Security -framework ServiceManagement -framework Network \\\n  -framework PDFKit -framework Vision \\', 1)
s = s.replace('Replyzen 1.17: New Mail erzeugt immer einen eigenen Betreff und Mailtext und befüllt beide Outlook-Felder automatisch; Preview zeigt beide Felder separat.',
              'Replyzen 1.18: schnellere Antworten mit GPT-5.4 Mini ohne Reasoning; robuster New-Mail-Body via Tab-Fallback; neue Überweisungsdaten-Extraktion aus Mail und lesbaren PDF/Bild-Anhängen.')
p.write_text(s)
