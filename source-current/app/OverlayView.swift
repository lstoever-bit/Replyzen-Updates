import SwiftUI
import AppKit

struct OverlayView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if isWorkspace {
                WorkspaceHeader(state: state)
                Divider()
                content
            } else {
                content.padding(28)
            }
        }
        .frame(minWidth: 590, minHeight: 390)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var isWorkspace: Bool {
        state.stage == .instruction || state.stage == .preview ||
        state.stage == .calendarPreview || state.stage == .paymentPreview
    }

    @ViewBuilder
    private var content: some View {
        switch state.stage {
        case .idle:
            readyView
        case .startup:
            startupView
        case .instruction:
            MailWorkspaceView(state: state)
        case .generating:
            loadingView(title: "Einen Moment", subtitle: generatingSubtitle)
        case .updating:
            loadingView(title: "Update wird installiert", subtitle: "Neue Version wird geladen und eingerichtet …")
        case .preview:
            MailDraftPreviewView(state: state)
        case .calendarPreview:
            ScrollView {
                calendarPreviewView
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { calendarFooter }
        case .paymentPreview:
            ScrollView {
                paymentPreviewView
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { paymentFooter }
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
                    Text("ReplyZen läuft")
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
                Button("ReplyZen öffnen") { state.retryAction?() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var readyView: some View {
        VStack(spacing: 16) {
            replyzenLogo(size: 72)
            Text(ReplyZenBrand.displayName)
                .font(.title2.bold())
            Text("Mail, Termin oder Überweisung, direkt aus Outlook.")
                .foregroundStyle(.secondary)
            Button("ReplyZen öffnen") {
                state.retryAction?()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func replyzenLogo(size: CGFloat) -> some View {
        Group {
            if let image = ReplyZenBrand.logo {
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

        }
    }

    private var paymentFooter: some View {
        WorkspaceActionBar(
            secondaryTitle: "Zurück", primaryTitle: "Überweisungsdaten kopieren",
            hint: "Es wird keine Zahlung ausgelöst.",
            disabled: state.paymentRecipient.isEmpty && state.paymentIBAN.isEmpty && state.paymentAmount.isEmpty,
            secondaryAction: { state.stage = .instruction },
            primaryAction: { state.copyPaymentAction?() }
        )
    }

    private var calendarFooter: some View {
        WorkspaceActionBar(
            secondaryTitle: "Zurück", primaryTitle: "Im Kalender anlegen",
            hint: "Zeit und Zielkalender prüfen.",
            disabled: state.calendarTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.calendarEnd <= state.calendarStart || state.selectedCalendarID.isEmpty || state.googleConnectedEmail.isEmpty,
            secondaryAction: { state.stage = .instruction },
            primaryAction: { state.createCalendarAction?() }
        )
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
            ScrollView {
                Text(state.errorMessage)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
