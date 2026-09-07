from pathlib import Path
import sys

root = Path(sys.argv[1])

# 1) AppState: add a dedicated startup screen and local joke text.
p = root / 'app' / 'AppState.swift'
s = p.read_text()
old = '''    enum Stage: Equatable {\n        case idle\n        case instruction\n'''
new = '''    enum Stage: Equatable {\n        case idle\n        case startup\n        case instruction\n'''
if old not in s:
    raise SystemExit('AppState Stage block not found')
s = s.replace(old, new, 1)
old = '''    @Published var statusText: String = ""\n    @Published var replyLanguage: ReplyLanguage = .german\n'''
new = '''    @Published var statusText: String = ""\n    @Published var startupJoke: String = ""\n    @Published var replyLanguage: ReplyLanguage = .german\n'''
if old not in s:
    raise SystemExit('AppState published block not found')
s = s.replace(old, new, 1)
p.write_text(s)

# 2) Overlay: render a compact launch confirmation with a joke.
p = root / 'app' / 'OverlayView.swift'
s = p.read_text()
old = '''        switch state.stage {\n        case .idle:\n            readyView\n        case .instruction:\n'''
new = '''        switch state.stage {\n        case .idle:\n            readyView\n        case .startup:\n            startupView\n        case .instruction:\n'''
if old not in s:
    raise SystemExit('Overlay stage switch not found')
s = s.replace(old, new, 1)
marker = '''    private var readyView: some View {\n'''
startup_view = '''    private var startupView: some View {\n        VStack(alignment: .leading, spacing: 18) {\n            HStack(spacing: 12) {\n                replyzenLogo(size: 46)\n                VStack(alignment: .leading, spacing: 2) {\n                    Text("Replyzen läuft")\n                        .font(.title2.bold())\n                    Text("Bereit in Outlook · ⌃⌥R oder ✨ AI")\n                        .font(.callout)\n                        .foregroundStyle(.secondary)\n                }\n                Spacer()\n                Image(systemName: "checkmark.circle.fill")\n                    .font(.title2)\n                    .foregroundStyle(.secondary)\n            }\n\n            VStack(alignment: .leading, spacing: 7) {\n                Text("Witz zum Start")\n                    .font(.caption)\n                    .foregroundStyle(.secondary)\n                Text(state.startupJoke)\n                    .font(.title3)\n                    .fixedSize(horizontal: false, vertical: true)\n            }\n            .padding(14)\n            .frame(maxWidth: .infinity, alignment: .leading)\n            .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))\n\n            HStack {\n                Button("Schließen") { state.closeAction?() }\n                Spacer()\n                Button("Replyzen öffnen") { state.retryAction?() }\n                    .keyboardShortcut(.defaultAction)\n            }\n        }\n    }\n\n'''
if marker not in s:
    raise SystemExit('readyView marker not found')
s = s.replace(marker, startup_view + marker, 1)
p.write_text(s)

# 3) AppDelegate: suppress any legacy/restored Settings window and show startup screen.
p = root / 'app' / 'AppDelegate.swift'
s = p.read_text()
old = '''    func applicationDidFinishLaunching(_ notification: Notification) {\n        NSApp.setActivationPolicy(.accessory)\n\n        migrateExistingAPIKeyIfPossible()\n'''
new = '''    func applicationDidFinishLaunching(_ notification: Notification) {\n        NSApp.setActivationPolicy(.accessory)\n        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")\n        suppressLegacySettingsWindows()\n        DispatchQueue.main.async { [weak self] in self?.suppressLegacySettingsWindows() }\n        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.suppressLegacySettingsWindows() }\n\n        migrateExistingAPIKeyIfPossible()\n'''
if old not in s:
    raise SystemExit('AppDelegate launch header not found')
s = s.replace(old, new, 1)
old = '''        if keychain.loadAPIKey() == nil {\n            state.stage = .apiKey\n            panel.show()\n        } else {\n            state.stage = .idle\n        }\n'''
new = '''        if keychain.loadAPIKey() == nil {\n            state.stage = .apiKey\n            panel.show()\n        } else {\n            state.startupJoke = startupJoke()\n            state.stage = .startup\n            panel.show(activate: true)\n        }\n'''
if old not in s:
    raise SystemExit('AppDelegate initial stage block not found')
s = s.replace(old, new, 1)
insert_before = '''    private func configureStateActions() {\n'''
helpers = '''    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool {\n        false\n    }\n\n    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool {\n        false\n    }\n\n    private func suppressLegacySettingsWindows() {\n        for window in NSApp.windows {\n            let title = window.title.lowercased()\n            if title.contains("replyzen-einstellungen") || title.contains("replyzen settings") {\n                window.orderOut(nil)\n                window.close()\n            }\n        }\n    }\n\n    private func startupJoke() -> String {\n        let jokes = [\n            "Warum sind E-Mails schlechte Geheimnisträger? Weil am Ende doch jemand auf ‚Allen antworten‘ klickt.",\n            "Mein Kalender wollte spontan sein. Ich habe ihm dafür einen Termin eingetragen.",\n            "CC ist die höfliche Art zu sagen: Jetzt weißt du es auch.",\n            "Warum war die Mail so entspannt? Sie hatte keinen Anhang zu tragen.",\n            "Der kürzeste Büro-Witz? ‚Kurze Abstimmung‘.",\n            "Ich wollte meinem Posteingang Urlaub geben. Er hat die Abwesenheitsnotiz abgelehnt.",\n            "Warum mag Replyzen Montagmorgen? Weil selbst eine kurze Antwort schon wie Fortschritt aussieht.",\n            "Mein Kalender und ich haben eine gute Beziehung: Er sagt mir ständig, wo ich sein soll.",\n            "Eine E-Mail ohne Betreff ist wie ein Termin ohne Uhrzeit: spannend, aber unnötig.",\n            "Warum hat der Termin nicht zurückgerufen? Er war schon vergeben."\n        ]\n        return jokes.randomElement() ?? "Replyzen läuft. Das ist heute schon die halbe Miete."\n    }\n\n'''
if insert_before not in s:
    raise SystemExit('AppDelegate configureStateActions marker not found')
s = s.replace(insert_before, helpers + insert_before, 1)
p.write_text(s)

# 4) Version bump.
p = root / 'app' / 'Info.plist'
s = p.read_text()
s = s.replace('<string>1.8.0</string>', '<string>1.9.0</string>', 1)
s = s.replace('<string>9</string>', '<string>10</string>', 1)
p.write_text(s)

# 5) Update notes.
p = root / 'Build-CI.sh'
s = p.read_text()
s = s.replace('Replyzen 1.8: deutlich größeres Terminfenster; Terminansicht scrollt bei kleinen Displays, damit nichts abgeschnitten wird.',
              'Replyzen 1.9: altes leeres Einstellungsfenster wird unterdrückt; beim Start erscheint eine Bestätigung mit lokalem Zufallswitz.')
p.write_text(s)
