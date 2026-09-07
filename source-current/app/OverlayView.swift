import SwiftUI
import AppKit

struct OverlayView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)

            content
                .padding(28)
        }
        .frame(minWidth: 590, minHeight: 390)
    }

    @ViewBuilder
    private var content: some View {
        switch state.stage {
        case .idle:
            readyView
        case .startup:
            startupView
        case .instruction:
            instructionView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .generating:
            loadingView(title: "Einen Moment", subtitle: generatingSubtitle)
        case .updating:
            loadingView(title: "Update wird installiert", subtitle: "Neue Version wird geladen und eingerichtet …")
        case .preview:
            ScrollView {
                previewView
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 6)
            }
        case .calendarPreview:
            ScrollView {
                calendarPreviewView
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .paymentPreview:
            ScrollView {
                paymentPreviewView
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .inserting:
            loadingView(title: "Fast fertig", subtitle: insertingSubtitle)
        case .success:
            successView
        case .needsAccessibility:
            accessibilityView
        case .apiKey:
            apiKeyView
        case .error:
            errorView
        }
    }

    private var startupView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                replyzenLogo(size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Replyzen läuft")
                        .font(.title2.bold())
                    Text("Bereit in Outlook · ⌃⌥R oder ✨ AI")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Witz zum Start")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(state.startupJoke)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Button("Schließen") { state.closeAction?() }
                Spacer()
                Button("Replyzen öffnen") { state.retryAction?() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var readyView: some View {
        VStack(spacing: 16) {
            replyzenLogo(size: 72)
            Text("Replyzen")
                .font(.title2.bold())
            Text("Mail, Termin oder Überweisung, direkt aus Outlook.")
                .foregroundStyle(.secondary)
            Button("Replyzen öffnen") {
                state.retryAction?()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func replyzenLogo(size: CGFloat) -> some View {
        Group {
            if let url = Bundle.main.url(forResource: "ReplyzenLogo", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "envelope.badge")
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }

    private var generatingSubtitle: String {
        switch state.outputMode {
        case .reply: return "Ich erstelle deine Antwort …"
        case .newMail: return "Ich formuliere deine neue Mail …"
        case .forward: return "Ich bereite die Weiterleitung vor …"
        case .calendar: return "Ich erstelle einen kurzen Termintitel und erkenne den Zeitpunkt …"
        case .payment: return "Ich lese den PDF-Anhang und extrahiere die Überweisungsdaten …"
        }
    }

    private var insertingSubtitle: String {
        switch state.outputMode {
        case .newMail:
            return "Ich öffne eine neue Outlook-Mail und setze den Text ein …"
        case .forward:
            return "Ich öffne die Outlook-Weiterleitung und setze deinen Text über den Thread …"
        case .reply:
            return "Ich setze die Antwort in Outlook ein …"
        case .calendar, .payment:
            return "Fast fertig …"
        }
    }

    private func loadingView(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                replyzenLogo(size: 34)
                Text(title)
                    .font(.title2.bold())
            }

            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)

            IndeterminateBar()
                .frame(height: 14)

            if !state.statusText.isEmpty {
                Text(state.statusText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var instructionView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                replyzenLogo(size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Replyzen")
                        .font(.title2.bold())
                    Text("Mail AI")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if state.outputMode == .reply || state.outputMode == .newMail || state.outputMode == .forward {
                mailTypeSelector
            } else {
                mailContextBanner
            }

            if state.outputMode == .calendar {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar.badge.plus")
                            .font(.title2)
                        Text("Termin aus Mail erstellen")
                            .font(.title3.bold())
                    }
                    Text("Replyzen erstellt aus dem Mailverlauf einen möglichst kurzen Titel, einen extrem kompakten Termintext und übernimmt einen eindeutig erkennbaren Terminzeitpunkt. Den Zielkalender wählst du vor dem Anlegen aus.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                .padding(14)
                .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            } else if state.outputMode == .payment {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "banknote")
                            .font(.title2)
                        Text("Überweisung aus Mail + PDF")
                            .font(.title3.bold())
                    }
                    Text("Replyzen liest den PDF-Anhang standardmäßig direkt mit OpenAI und extrahiert daraus Empfänger, IBAN, BIC, Betrag, Währung und Verwendungszweck. Der Mailtext dient nur als zusätzlicher Kontext.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                .padding(14)
                .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            } else {
                RichTextMailEditor(
                    plainText: $state.instruction,
                    html: $state.instructionHTML,
                    height: 320,
                    showsHTMLBadge: false
                )
            }

            HStack(spacing: 10) {
                if state.outputMode == .reply || state.outputMode == .newMail || state.outputMode == .forward {
                    HStack(spacing: 7) {
                        Text("Mood")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Mood", selection: $state.replyTone) {
                            ForEach(ReplyTone.allCases) { tone in
                                Text(tone.displayName).tag(tone)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(minWidth: 130)

                        Toggle("Compact", isOn: $state.newMailCompact)
                            .toggleStyle(.checkbox)
                            .help("Erstellt eine möglichst kurze Mail")
                    }
                }

                Spacer()

                if state.outputMode != .payment {
                    languageButton("🇩🇪", language: .german, help: "Ausgabe auf Deutsch")
                    languageButton("🇺🇸", language: .usEnglish, help: "Ausgabe in US English")
                }
            }

            if state.outputMode == .reply || state.outputMode == .newMail || state.outputMode == .forward {
                reminderRow
            }

            if state.outputMode == .calendar {
                Text("Sprache: \(state.replyLanguage.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if state.outputMode == .payment {
                HStack(spacing: 6) {
                    Image(systemName: "doc.richtext")
                    Text("PDF wird direkt von OpenAI gelesen")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Divider()

            HStack(spacing: 12) {
                Button("Schließen") { state.closeAction?() }
                    .controlSize(.large)

                Spacer()

                Button(primaryActionTitle) { state.generateAction?() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(minWidth: 170)
                    .keyboardShortcut(.defaultAction)
                    .disabled(primaryActionDisabled)
            }
            .padding(.top, 2)
        }
    }

    private var reminderRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        state.reminderEnabled.toggle()
                    }
                } label: {
                    Label("Reminder", systemImage: state.reminderEnabled ? "bell.fill" : "bell")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if state.reminderEnabled {
                    Text("BCC")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(reminderAddress)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if state.reminderEnabled {
                HStack(spacing: 9) {
                    ForEach(reminderDays, id: \.code) { day in
                        Button { state.reminderDay = day.code } label: {
                            HStack(spacing: 4) {
                                Image(systemName: state.reminderDay == day.code ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 11))
                                Text(day.label)
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }

                    Divider()
                        .frame(height: 20)
                        .padding(.horizontal, 2)

                    Picker("Zeit", selection: $state.reminderTime) {
                        ForEach(reminderTimes, id: \.self) { time in
                            Text(time).tag(time)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 90)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.background.opacity(0.42), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private var reminderDays: [(label: String, code: String)] {
        [("Mo", "mon"), ("Di", "tues"), ("Mi", "wed"), ("Do", "thurs"), ("Fr", "fri"), ("Sa", "sat"), ("So", "sun")]
    }

    private var reminderTimes: [String] {
        (0...48).map { slot in
            if slot == 48 { return "24:00" }
            let hour = slot / 2
            let minute = slot % 2 == 0 ? 0 : 30
            return String(format: "%02d:%02d", hour, minute)
        }
    }

    private var reminderAddress: String {
        let compactTime = state.reminderTime.replacingOccurrences(of: ":", with: "")
        if compactTime == "0600" {
            return "\(state.reminderDay)@fut.io"
        }
        return "\(state.reminderDay)\(compactTime)@fut.io"
    }

    private var modeSelector: some View {
        HStack(spacing: 8) {
            modeButton(.reply, title: "Mail", systemImage: "envelope.fill")
            modeButton(.payment, title: "Überweisung", systemImage: "banknote")
        }
    }

    private var mailTypeSelector: some View {
        HStack(spacing: 8) {
            if mailAvailable {
                mailTypeButton(.reply, title: "Reply", systemImage: "arrowshape.turn.up.left.fill")
            }
            mailTypeButton(.newMail, title: "New Mail", systemImage: "square.and.pencil")
            if mailAvailable {
                mailTypeButton(.forward, title: "Forward", systemImage: "arrowshape.turn.up.right")
            }

            if !mailAvailable {
                HStack(spacing: 5) {
                    if case .loading = state.mailStatus {
                        ProgressView().controlSize(.mini)
                        Text("Prüfe Outlook-Mail …")
                    } else {
                        Image(systemName: "info.circle")
                        Text("Keine Mail erkannt. Reply und Forward sind ausgeblendet.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            }

            Spacer(minLength: 0)
        }
    }

    private func mailTypeButton(_ mode: AppState.OutputMode, title: String, systemImage: String) -> some View {
        Button {
            guard state.outputMode != mode else { return }
            state.outputMode = mode
            handleModeChange(mode)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(state.outputMode == mode ? .accentColor : .gray.opacity(0.32))
        .controlSize(.small)
    }

    private func modeButton(_ mode: AppState.OutputMode, title: String, systemImage: String) -> some View {
        Button {
            guard state.outputMode != mode else { return }
            state.outputMode = mode
            handleModeChange(mode)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .tint(isTopLevelModeSelected(mode) ? .accentColor : .gray.opacity(0.32))
        .controlSize(.regular)
    }

    private func isTopLevelModeSelected(_ mode: AppState.OutputMode) -> Bool {
        if mode == .reply {
            return state.outputMode == .reply || state.outputMode == .newMail || state.outputMode == .forward
        }
        return state.outputMode == mode
    }

    @ViewBuilder
    private var mailContextBanner: some View {
        switch state.mailStatus {
        case .notChecked:
            EmptyView()
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Aktuelle Outlook-Mail wird im Hintergrund geladen …")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        case .available:
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                Text("Outlook-Mail erkannt")
                    .font(.callout)
            }
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        case .unavailable(let message):
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "info.circle")
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Erneut versuchen") { state.refreshMailAction?() }
                    .controlSize(.small)
            }
            .padding(10)
            .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var primaryActionTitle: String {
        switch state.outputMode {
        case .reply: return "Antwort erstellen"
        case .newMail: return "Mail erstellen"
        case .forward: return "Forward erstellen"
        case .calendar: return "Termin erstellen"
        case .payment: return "Überweisung extrahieren"
        }
    }

    private var primaryActionDisabled: Bool {
        switch state.outputMode {
        case .reply:
            return !mailAvailable || state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .newMail:
            return state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .forward:
            return !mailAvailable || state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .calendar, .payment:
            return !mailAvailable
        }
    }

    private var mailAvailable: Bool {
        if case .available = state.mailStatus { return true }
        return false
    }

    private func handleModeChange(_ mode: AppState.OutputMode) {
        switch mode {
        case .newMail:
            // Same form, same user input. Only remove Replyzen's own built-in
            // reply suggestion if it is still untouched.
            let trimmed = state.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "Kurz, freundlich und direkt antworten." ||
               trimmed == "Reply briefly, friendly and directly." {
                state.instruction = ""
                state.instructionHTML = ""
            }
            state.newMailSubject = ""
        case .reply:
            if state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state.instruction = state.replyLanguage == .german
                    ? "Kurz, freundlich und direkt antworten."
                    : "Reply briefly, friendly and directly."
                state.instructionHTML = ""
            }
        case .forward:
            let trimmed = state.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "Kurz, freundlich und direkt antworten." ||
               trimmed == "Reply briefly, friendly and directly." {
                state.instruction = ""
                state.instructionHTML = ""
            }
        case .calendar, .payment:
            break
        }
    }

    private func languageButton(_ label: String, language: AppState.ReplyLanguage, help: String) -> some View {
        Button {
            state.replyLanguage = language
        } label: {
            Text(label)
                .font(.system(size: 20))
                .frame(width: 34, height: 24)
        }
        .buttonStyle(.borderedProminent)
        .tint(state.replyLanguage == language ? .accentColor : .gray.opacity(0.35))
        .controlSize(.small)
        .help(help)
        .accessibilityLabel(help)
    }

    private var previewView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(previewTitle)
                .font(.title2.bold())

            if state.outputMode == .newMail {
                TextField("Betreff", text: $state.newMailSubject)
                    .textFieldStyle(.roundedBorder)
            }

            RichTextMailEditor(
                plainText: $state.reply,
                html: $state.replyHTML
            )

            HStack {
                Button("Zurück") {
                    state.stage = .instruction
                }
                Spacer()

                Button(state.outputMode == .newMail ? "Neue Mail in Outlook" : "In Outlook einsetzen") {
                    state.insertAction?()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }


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

    private var calendarPreviewView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.plus")
                    .font(.title2)
                Text("Termin prüfen")
                    .font(.title2.bold())
            }

            if !state.calendarWarning.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(state.calendarWarning)
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
                .padding(10)
                .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Titel").font(.caption).foregroundStyle(.secondary)
                TextField("Kurzer Termintitel", text: $state.calendarTitle)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Worum geht es?").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $state.calendarNotes)
                    .font(.body)
                    .frame(height: 58)
                    .padding(6)
                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Start").font(.caption).foregroundStyle(.secondary)
                    DatePicker("", selection: $state.calendarStart, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .environment(\.timeZone, CalendarManager.eventTimeZone)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ende").font(.caption).foregroundStyle(.secondary)
                    DatePicker("", selection: $state.calendarEnd, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .environment(\.timeZone, CalendarManager.eventTimeZone)
                }
                Spacer()
            }

            Text("Zeitzone: CET / Europe-Berlin")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "g.circle.fill")
                    Text("Google Calendar · lennard@minubo.com")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !state.googleConnectedEmail.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }

                if state.googleNeedsOAuthCredentials {
                    Text("Einmalig Google OAuth einrichten: Google Calendar API aktivieren und einen OAuth-Client vom Typ „Desktop-App“ erstellen. Client-ID und Client Secret hier einfügen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Google OAuth Client-ID", text: $state.googleClientIDDraft)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Google OAuth Client Secret", text: $state.googleClientSecretDraft)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Google Cloud öffnen") { state.openGoogleCloudAction?() }
                        Spacer()
                        Button(state.googleIsConnecting ? "Verbinde …" : "Speichern & Google verbinden") {
                            state.connectGoogleCalendarAction?()
                        }
                        .disabled(state.googleIsConnecting)
                    }
                } else if state.googleConnectedEmail.isEmpty {
                    HStack(spacing: 8) {
                        if state.googleIsConnecting { ProgressView().controlSize(.small) }
                        Text(state.googleOAuthStatus.isEmpty ? "Noch nicht verbunden." : state.googleOAuthStatus)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("OAuth-Zugang ändern") { state.googleNeedsOAuthCredentials = true }
                        Spacer()
                        Button("Mit Google verbinden") { state.connectGoogleCalendarAction?() }
                            .disabled(state.googleIsConnecting)
                    }
                } else {
                    HStack {
                        Text("Verbunden: \(state.googleConnectedEmail)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Trennen") { state.disconnectGoogleCalendarAction?() }
                            .controlSize(.small)
                    }

                    if state.calendarOptions.isEmpty {
                        HStack(spacing: 8) {
                            if state.calendarListStatus.contains("geladen") {
                                ProgressView().controlSize(.small)
                            }
                            Text(state.calendarListStatus)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("Kalender", selection: $state.selectedCalendarID) {
                            ForEach(state.calendarOptions) { calendar in
                                Text(calendar.title).tag(calendar.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 360, alignment: .leading)
                    }
                }
            }

            Spacer()

            HStack {
                Button("Zurück") { state.stage = .instruction }
                Spacer()
                Button("Im Kalender anlegen") { state.createCalendarAction?() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.calendarTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.calendarEnd <= state.calendarStart || state.selectedCalendarID.isEmpty || state.googleConnectedEmail.isEmpty)
            }
        }
    }

    private var previewTitle: String {
        switch state.outputMode {
        case .reply: return "Antwortvorschlag"
        case .newMail: return "Neue Mail"
        case .forward: return "Weiterleitung"
        case .calendar: return "Termin"
        case .payment: return "Überweisung"
        }
    }

    private var successView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42))
            Text("Fertig")
                .font(.title2.bold())
            Text(state.outputMode == .calendar
                 ? state.successMessage
                 : (state.outputMode == .newMail
                    ? "Der Text wurde in eine neue Outlook-Mail eingesetzt. Bitte Empfänger und Betreff ergänzen, prüfen und selbst senden."
                    : "Die Antwort ist in Outlook eingesetzt. Bitte noch kurz prüfen und selbst senden."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Schließen") { state.closeAction?() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var accessibilityView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Einmalige Berechtigung")
                .font(.title2.bold())
            Text("Für das Lesen aus Outlook und das automatische Einsetzen braucht Replyzen Zugriff auf Bedienungshilfen. New Mail erstellen kannst du auch ohne Mail-Kontext.")
                .foregroundStyle(.secondary)
            Text("Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen → Replyzen einschalten.")
                .font(.callout)
            HStack {
                Button("Systemeinstellungen öffnen") { state.openAccessibilityAction?() }
                Spacer()
                Button("Zurück zu Replyzen") { state.retryAction?() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var apiKeyView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("OpenAI API-Key")
                .font(.title2.bold())
            Text("Der Key wird einmalig im macOS-Schlüsselbund gespeichert.")
                .foregroundStyle(.secondary)

            SecureField("sk-…", text: $state.apiKeyDraft)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Abbrechen") { state.closeAction?() }
                Spacer()
                Button("Speichern") { state.saveAPIKeyAction?() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var errorView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
            Text("Das hat nicht geklappt")
                .font(.title2.bold())
            Text(state.errorMessage)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("Schließen") { state.closeAction?() }
                Spacer()
                Button("Zurück") {
                    state.stage = .instruction
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct CommandManagerView: View {
    @ObservedObject var store: CommandStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: UUID?
    @State private var draftName = ""
    @State private var draftPrompt = ""
    @State private var draftTone: ReplyTone = .professional

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Commands")
                        .font(.title2.bold())
                    Text("Name, Prompt und Tone festlegen. Die Sprache steuerst du weiterhin über 🇩🇪 / 🇺🇸.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("+ Add Command") {
                    let command = store.addCommand()
                    select(command)
                }
            }

            HStack(alignment: .top, spacing: 18) {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(store.commands) { command in
                            Button {
                                select(command)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(command.name)
                                            .fontWeight(.medium)
                                        Text(command.tone.displayName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(selectedID == command.id ? Color.accentColor.opacity(0.14) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(width: 190, height: 270)
                .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Command name", text: $draftName)
                        .textFieldStyle(.roundedBorder)

                    Text("Prompt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $draftPrompt)
                        .frame(height: 112)
                        .padding(6)
                        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))

                    HStack {
                        Text("Tone")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Tone", selection: $draftTone) {
                            ForEach(ReplyTone.allCases) { tone in
                                Text(tone.displayName).tag(tone)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }

                    Spacer()

                    HStack {
                        Button("Delete", role: .destructive) {
                            deleteSelected()
                        }
                        .disabled(selectedID == nil)

                        Spacer()

                        Button("Save") {
                            saveSelected()
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                    }
                }
                .frame(width: 360, height: 270)
            }

            Divider()

            HStack {
                Button("Reset Defaults") {
                    store.resetToDefaults()
                    if let first = store.commands.first { select(first) }
                }
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(22)
        .frame(width: 620, height: 410)
        .onAppear {
            if let first = store.commands.first {
                select(first)
            }
        }
    }

    private var canSave: Bool {
        selectedID != nil &&
        !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func select(_ command: ReplyCommand) {
        selectedID = command.id
        draftName = command.name
        draftPrompt = command.prompt
        draftTone = command.tone
    }

    private func saveSelected() {
        guard let id = selectedID else { return }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty else { return }

        store.update(ReplyCommand(id: id, name: name, prompt: prompt, tone: draftTone))
    }

    private func deleteSelected() {
        guard let id = selectedID else { return }
        store.delete(id: id)
        if let first = store.commands.first {
            select(first)
        } else {
            selectedID = nil
            draftName = ""
            draftPrompt = ""
            draftTone = .professional
        }
    }
}
