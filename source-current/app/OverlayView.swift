import SwiftUI
import AppKit

struct OverlayView: View {
    @ObservedObject var state: AppState
    @ObservedObject var commands: CommandStore
    @State private var showCommandManager = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)

            content
                .padding(28)
        }
        .frame(minWidth: 590, minHeight: 390)
        .sheet(isPresented: $showCommandManager) {
            CommandManagerView(store: commands)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.stage {
        case .idle:
            readyView
        case .startup:
            startupView
        case .instruction:
            ScrollView {
                instructionView
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 6)
            }
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
            Text("Reply, New Mail oder Termin – direkt aus Outlook.")
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
        case .calendar: return "Ich erstelle einen kurzen Termintitel und erkenne den Zeitpunkt …"
        }
    }

    private var insertingSubtitle: String {
        state.outputMode == .newMail
            ? "Ich öffne eine neue Outlook-Mail und setze den Text ein …"
            : "Ich setze die Antwort in Outlook ein …"
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

            Picker("Modus", selection: $state.outputMode) {
                ForEach(AppState.OutputMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: state.outputMode) { mode in
                handleModeChange(mode)
            }

            if state.outputMode != .newMail {
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
            } else {
                Text(state.outputMode == .reply ? "Was soll ich antworten?" : "Was soll ich schreiben?")
                    .font(.title3.bold())

                TextEditor(text: $state.instruction)
                    .font(.body)
                    .frame(height: 122)
                    .padding(8)
                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topLeading) {
                        if state.instruction.isEmpty {
                            Text(state.outputMode == .reply
                                 ? "z. B. Sehr kurz, freundlich und direkt antworten."
                                 : "z. B. Schreibe eine kurze Mail an Max und frage nach einem Termin nächste Woche.")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 14)
                                .padding(.top, 16)
                                .allowsHitTesting(false)
                        }
                    }
            }

            HStack(spacing: 8) {
                if state.outputMode != .calendar {
                    Menu {
                        ForEach(commands.commands) { command in
                            Button(command.name) {
                                applyCommand(command)
                            }
                        }

                        Divider()

                        Button("+ Add Command…") {
                            showCommandManager = true
                        }
                        Button("Manage Commands…") {
                            showCommandManager = true
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "slider.horizontal.3")
                            Text("Commands")
                        }
                    }
                    .controlSize(.small)
                    .help("Eigene Replyzen-Befehle auswählen oder verwalten")
                }

                Spacer()

                languageButton("🇩🇪", language: .german, help: "Ausgabe auf Deutsch")
                languageButton("🇺🇸", language: .usEnglish, help: "Ausgabe in US English")
            }

            if state.outputMode != .calendar {
                HStack(spacing: 6) {
                    Text("Command: \(state.selectedCommandName)")
                    Text("·")
                    Text("Tone: \(state.replyTone.displayName)")
                    Text("·")
                    Text("Sprache: \(state.replyLanguage.displayName)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Sprache: \(state.replyLanguage.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Schließen") { state.closeAction?() }
                Spacer()
                Button(primaryActionTitle) { state.generateAction?() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(primaryActionDisabled)
            }
        }
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
        case .calendar: return "Termin erstellen"
        }
    }

    private var primaryActionDisabled: Bool {
        switch state.outputMode {
        case .reply:
            return !mailAvailable || state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .newMail:
            return state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .calendar:
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
            state.instruction = ""
            state.selectedCommandName = "Custom"
            state.replyTone = .professional
        case .reply:
            if state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let first = commands.commands.first {
                applyCommand(first)
            }
        case .calendar:
            break
        }
    }

    private func applyCommand(_ command: ReplyCommand) {
        state.selectedCommandName = command.name
        state.instruction = command.prompt
        state.replyTone = command.tone
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

            TextEditor(text: $state.reply)
                .font(.body)
                .frame(height: 190)
                .padding(8)
                .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))

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
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ende").font(.caption).foregroundStyle(.secondary)
                    DatePicker("", selection: $state.calendarEnd, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
                Spacer()
            }

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
        case .calendar: return "Termin"
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
