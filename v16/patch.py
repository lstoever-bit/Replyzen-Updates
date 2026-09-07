from pathlib import Path
import re
import sys

root = Path(sys.argv[1])

def read(rel):
    return (root / rel).read_text()

def write(rel, text):
    (root / rel).write_text(text)

def replace_once(text, old, new, label):
    if old not in text:
        raise SystemExit(f"missing expected text for {label}")
    return text.replace(old, new, 1)

# Build settings: direct Google API, no EventKit.
p = "Build-CI.sh"
s = read(p)
s = replace_once(s,
    "-framework Security -framework ServiceManagement -framework EventKit \\",
    "-framework Security -framework ServiceManagement -framework Network \\",
    "frameworks")
s = replace_once(s,
    '"notes": "Replyzen 1.5: Termin-Body extrem kompakt; Auswahl des Zielkalenders innerhalb des minubo-Kontos."',
    '"notes": "Replyzen 1.6: direkte Google-Calendar-API mit OAuth; Kalenderauswahl und kompakter Termin-Body."',
    "update notes")
write(p, s)

# Version and remove Apple Calendar permissions.
p = "app/Info.plist"
s = read(p)
s = replace_once(s, "<string>1.5.0</string>", "<string>1.6.0</string>", "version")
s = replace_once(s, "<string>6</string>", "<string>7</string>", "build")
s = s.replace('    <key>NSCalendarsUsageDescription</key>\n    <string>Replyzen legt auf Wunsch Termine in einem ausgewählten Kalender des minubo-Kontos an.</string>\n', '')
s = s.replace('    <key>NSCalendarsFullAccessUsageDescription</key>\n    <string>Replyzen braucht Kalenderzugriff, um Kalender des minubo-Kontos auszuwählen und Termine anzulegen.</string>\n', '')
write(p, s)

# State for Google OAuth.
p = "app/AppState.swift"
s = read(p)
s = replace_once(s,
'''    @Published var calendarListStatus: String = "Kalender werden geladen …"
    @Published var successMessage: String = ""
''',
'''    @Published var calendarListStatus: String = "Google-Kalender werden geladen …"
    @Published var googleNeedsOAuthCredentials: Bool = false
    @Published var googleClientIDDraft: String = ""
    @Published var googleClientSecretDraft: String = ""
    @Published var googleConnectedEmail: String = ""
    @Published var googleOAuthStatus: String = ""
    @Published var googleIsConnecting: Bool = false
    @Published var successMessage: String = ""
''', "google state")
s = replace_once(s,
'''    var createCalendarAction: (() -> Void)?
    var retryAction: (() -> Void)?
''',
'''    var createCalendarAction: (() -> Void)?
    var connectGoogleCalendarAction: (() -> Void)?
    var disconnectGoogleCalendarAction: (() -> Void)?
    var openGoogleCloudAction: (() -> Void)?
    var retryAction: (() -> Void)?
''', "google actions")
write(p, s)

# Give OAuth setup a little more room.
p = "app/FloatingPanelController.swift"
s = read(p)
s = replace_once(s, "width: 620, height: 430", "width: 620, height: 510", "panel height")
write(p, s)

# AppDelegate wiring and direct Google OAuth behavior.
p = "app/AppDelegate.swift"
s = read(p)
s = replace_once(s,
'''        state.createCalendarAction = { [weak self] in self?.createCalendarEvent() }
        state.retryAction = { [weak self] in self?.openWorkspace() }
''',
'''        state.createCalendarAction = { [weak self] in self?.createCalendarEvent() }
        state.connectGoogleCalendarAction = { [weak self] in self?.connectGoogleCalendar() }
        state.disconnectGoogleCalendarAction = { [weak self] in self?.disconnectGoogleCalendar() }
        state.openGoogleCloudAction = { [weak self] in self?.openGoogleCloudCredentials() }
        state.retryAction = { [weak self] in self?.openWorkspace() }
''', "delegate actions")
s = replace_once(s,
    'state.statusText = "Termin wird im ausgewählten Kalender angelegt"',
    'state.statusText = "Termin wird direkt in Google Calendar angelegt"',
    "calendar status")
s = replace_once(s,
    'self.state.successMessage = "„\\(title)“ wurde am \\(formatter.string(from: self.state.calendarStart)) im Kalender „\\(selectedCalendarName)“ angelegt."',
    'self.state.successMessage = "„\\(title)“ wurde am \\(formatter.string(from: self.state.calendarStart)) direkt in Google Calendar · „\\(selectedCalendarName)“ angelegt."',
    "success wording")

pattern = re.compile(r'''    private func loadCalendarOptions\(\) \{.*?\n    \}\n\n    private func parseISODate''', re.S)
replacement = '''    private func loadCalendarOptions() {
        state.calendarOptions = []
        state.selectedCalendarID = ""
        state.googleConnectedEmail = calendarManager.connectedEmail() ?? ""

        guard calendarManager.isConfigured() else {
            state.googleNeedsOAuthCredentials = true
            state.googleOAuthStatus = "Einmalig Google OAuth einrichten."
            state.calendarListStatus = "Google Calendar ist noch nicht verbunden."
            return
        }

        state.googleNeedsOAuthCredentials = false
        guard let email = calendarManager.connectedEmail() else {
            state.googleOAuthStatus = "Noch nicht mit Google verbunden."
            state.calendarListStatus = "Bitte mit lennard@minubo.com verbinden."
            return
        }

        guard email.caseInsensitiveCompare(CalendarManager.targetEmail) == .orderedSame else {
            calendarManager.disconnect()
            state.googleConnectedEmail = ""
            state.googleOAuthStatus = "Bitte mit lennard@minubo.com verbinden."
            state.calendarListStatus = "Falsches Google-Konto."
            return
        }

        state.googleConnectedEmail = email
        state.googleOAuthStatus = "Verbunden mit \(email)"
        state.calendarListStatus = "Google-Kalender werden geladen …"

        calendarManager.loadCalendarOptions { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let options):
                    self.state.calendarOptions = options
                    if options.isEmpty {
                        self.state.selectedCalendarID = ""
                        self.state.calendarListStatus = "Keine beschreibbaren Google-Kalender gefunden."
                        return
                    }

                    let savedID = UserDefaults.standard.string(forKey: "Replyzen.SelectedMinuboCalendarID") ?? ""
                    if options.contains(where: { $0.id == savedID }) {
                        self.state.selectedCalendarID = savedID
                    } else if let preferred = options.first(where: { $0.title.lowercased() == "minubo" }) {
                        self.state.selectedCalendarID = preferred.id
                    } else {
                        self.state.selectedCalendarID = options[0].id
                    }
                    self.state.calendarListStatus = ""
                case .failure(let error):
                    self.state.selectedCalendarID = ""
                    self.state.calendarListStatus = error.localizedDescription
                    self.state.googleOAuthStatus = error.localizedDescription
                }
            }
        }
    }

    private func connectGoogleCalendar() {
        let clientID = state.googleClientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = state.googleClientSecretDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        if !calendarManager.isConfigured() && (clientID.isEmpty || clientSecret.isEmpty) {
            state.googleNeedsOAuthCredentials = true
            state.googleOAuthStatus = "Bitte Client-ID und Client Secret eintragen."
            return
        }

        state.googleIsConnecting = true
        state.googleOAuthStatus = "Google-Anmeldung wird im Browser geöffnet …"

        calendarManager.connect(clientID: clientID, clientSecret: clientSecret) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.state.googleIsConnecting = false
                switch result {
                case .success(let email):
                    self.state.googleConnectedEmail = email
                    self.state.googleNeedsOAuthCredentials = false
                    self.state.googleClientSecretDraft = ""
                    self.state.googleOAuthStatus = "Verbunden mit \(email)"
                    self.loadCalendarOptions()
                case .failure(let error):
                    self.state.googleOAuthStatus = error.localizedDescription
                    self.state.calendarListStatus = error.localizedDescription
                }
            }
        }
    }

    private func disconnectGoogleCalendar() {
        calendarManager.disconnect()
        state.googleConnectedEmail = ""
        state.calendarOptions = []
        state.selectedCalendarID = ""
        state.googleOAuthStatus = "Google Calendar wurde getrennt."
        state.calendarListStatus = "Bitte erneut mit lennard@minubo.com verbinden."
    }

    private func openGoogleCloudCredentials() {
        if let url = URL(string: "https://console.cloud.google.com/apis/credentials") {
            NSWorkspace.shared.open(url)
        }
    }

    private func parseISODate'''
s, count = pattern.subn(replacement, s, count=1)
if count != 1:
    raise SystemExit("could not replace loadCalendarOptions block")
write(p, s)

# Calendar preview: OAuth setup + direct Google calendar dropdown.
p = "app/OverlayView.swift"
s = read(p)
pattern = re.compile(r'''            VStack\(alignment: \.leading, spacing: 6\) \{\n                Text\("Kalender · lennard@minubo.com"\).*?\n            \}\n\n            Spacer\(\)''', re.S)
replacement = '''            VStack(alignment: .leading, spacing: 8) {
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

            Spacer()'''
s, count = pattern.subn(replacement, s, count=1)
if count != 1:
    raise SystemExit("could not replace Google calendar UI block")

s = replace_once(s,
    '.disabled(state.calendarTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.calendarEnd <= state.calendarStart || state.selectedCalendarID.isEmpty)',
    '.disabled(state.calendarTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.calendarEnd <= state.calendarStart || state.selectedCalendarID.isEmpty || state.googleConnectedEmail.isEmpty)',
    "calendar create disabled")
write(p, s)

print("Replyzen 1.6 patch applied")
