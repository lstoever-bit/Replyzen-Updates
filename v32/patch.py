from pathlib import Path
import sys

root = Path(sys.argv[1])


def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f"{label} not found")
    return text.replace(old, new, 1)


# Toolbar overlay: add a second, compact one-click decline button next to Replyzen.
p = root / "app" / "OutlookToolbarButtonController.swift"
s = p.read_text()
s = must_replace(
    s,
    "    private let panel: NSPanel\n    private let button: NSButton\n    private var timer: Timer?\n    private var isSuppressed = false\n\n    var action: (() -> Void)?\n",
    "    private let panel: NSPanel\n    private let button: NSButton\n    private let declineButton: NSButton\n    private var timer: Timer?\n    private var isSuppressed = false\n\n    var action: (() -> Void)?\n    var declineAction: (() -> Void)?\n",
    "toolbar properties"
)
s = must_replace(s, "        let size = NSSize(width: 112, height: 34)\n", "        let size = NSSize(width: 206, height: 34)\n", "toolbar size")
s = must_replace(
    s,
    "        button = NSButton(frame: effect.bounds.insetBy(dx: 4, dy: 3))\n",
    "        button = NSButton(frame: NSRect(x: 4, y: 3, width: 112, height: 28))\n",
    "replyzen button frame"
)
anchor = "        effect.addSubview(button)\n\n        panel.contentView = effect\n"
insert = '''        declineButton = NSButton(frame: NSRect(x: 120, y: 3, width: 82, height: 28))
        declineButton.title = "Absage"
        declineButton.bezelStyle = .rounded
        declineButton.font = .systemFont(ofSize: 12.5, weight: .semibold)
        declineButton.alignment = .center
        declineButton.isBordered = false
        declineButton.setButtonType(.momentaryPushIn)
        declineButton.toolTip = "Freundliche knappe Absage direkt als Outlook-Antwort einsetzen"
        declineButton.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Absage")
        declineButton.imagePosition = .imageLeading

        effect.addSubview(button)
        effect.addSubview(declineButton)

        panel.contentView = effect
'''
s = must_replace(s, anchor, insert, "decline button creation")
s = must_replace(
    s,
    "        button.target = self\n        button.action = #selector(buttonClicked)\n",
    "        button.target = self\n        button.action = #selector(buttonClicked)\n        declineButton.target = self\n        declineButton.action = #selector(declineButtonClicked)\n",
    "decline target"
)
s = must_replace(
    s,
    "    @objc private func buttonClicked() {\n        action?()\n    }\n\n    private func update() {\n",
    "    @objc private func buttonClicked() {\n        action?()\n    }\n\n    @objc private func declineButtonClicked() {\n        declineAction?()\n    }\n\n    private func update() {\n",
    "decline selector"
)
p.write_text(s)


# OpenAI: dedicated ultra-short decline prompt with automatic language detection.
p = root / "app" / "OpenAIClient.swift"
s = p.read_text()
anchor = "    struct NewMailDraft: Decodable {\n"
method = '''    func generateQuickDecline(
        apiKey: String,
        mailText: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let systemInstructions = [
            "Draft a very short, friendly decline as an email reply.",
            "Automatically detect the language of the latest relevant incoming message and write the reply in that same language.",
            "If the thread mixes languages, use the language of the most recent request that is being declined.",
            "Keep it warm, polite and concise: normally 1-3 short sentences.",
            "Clearly decline the request or invitation, but do not invent a reason, excuse, date, promise or alternative unless it is explicitly supported by the email.",
            "Do not add a subject line, greeting-only filler, signature or the user's name.",
            "Return only the reply text."
        ].joined(separator: "\\n")

        performRequest(
            apiKey: apiKey,
            instructions: systemInstructions,
            input: "EMAIL THREAD:\\n\\(String(mailText.prefix(30_000)))",
            model: "gpt-5.6-luna",
            reasoningEffort: "none",
            maxOutputTokens: 180,
            lowVerbosity: true,
            completion: completion
        )
    }

'''
if anchor not in s:
    raise SystemExit("OpenAI NewMailDraft anchor not found")
s = s.replace(anchor, method + anchor, 1)
p.write_text(s)


# AppDelegate: wire the one-click decline and insert it directly into an Outlook reply draft.
p = root / "app" / "AppDelegate.swift"
s = p.read_text()
s = must_replace(
    s,
    "    private func configureToolbarButton() {\n        toolbarButton.action = { [weak self] in self?.openWorkspace() }\n        toolbarButton.start()\n    }\n",
    "    private func configureToolbarButton() {\n        toolbarButton.action = { [weak self] in self?.openWorkspace() }\n        toolbarButton.declineAction = { [weak self] in self?.quickDecline() }\n        toolbarButton.start()\n    }\n",
    "toolbar decline wiring"
)
anchor = "    @objc private func menuReply() {\n"
quick = '''    private func quickDecline() {
        guard !isRunningFlow else { return }
        guard let apiKey = keychain.loadAPIKey() else {
            openWorkspace()
            return
        }
        guard outlook.isTrusted() else {
            outlook.requestTrustPrompt()
            return
        }

        isRunningFlow = true
        toolbarButton.setSuppressed(true)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            do {
                var snapshot = try self.outlook.captureSnapshot(includeAllWindows: false)
                var mail: String
                do {
                    mail = try self.outlook.readMail(from: snapshot)
                } catch OutlookAccessibility.OutlookError.noMailText {
                    snapshot = try self.outlook.captureSnapshot(includeAllWindows: true)
                    mail = try self.outlook.readMail(from: snapshot)
                }

                self.openAI.generateQuickDecline(apiKey: apiKey, mailText: mail) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        switch result {
                        case .success(let text):
                            let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !reply.isEmpty else {
                                self.isRunningFlow = false
                                self.toolbarButton.setSuppressed(false)
                                self.showSimpleAlert(title: "Absage fehlgeschlagen", message: "OpenAI hat keinen Antworttext geliefert.")
                                return
                            }
                            self.activeSnapshot = snapshot
                            self.insertQuickReply(reply, snapshot: snapshot)
                        case .failure(let error):
                            self.isRunningFlow = false
                            self.toolbarButton.setSuppressed(false)
                            self.showSimpleAlert(title: "Absage fehlgeschlagen", message: error.localizedDescription)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRunningFlow = false
                    self.toolbarButton.setSuppressed(false)
                    self.showSimpleAlert(title: "Absage fehlgeschlagen", message: "Die geöffnete Outlook-Mail konnte nicht gelesen werden.")
                }
            }
        }
    }

    private func insertQuickReply(_ reply: String, snapshot: OutlookAccessibility.Snapshot) {
        copyToPasteboard(reply)
        panel.hide()
        outlook.activateOutlook(pid: snapshot.pid)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.keyboard.sendCommandR()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.copyToPasteboard(reply)
                self.keyboard.sendCommandV()
                self.isRunningFlow = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.toolbarButton.setSuppressed(false)
                }
            }
        }
    }

'''
if anchor not in s:
    raise SystemExit("menuReply anchor not found")
s = s.replace(anchor, quick + anchor, 1)
p.write_text(s)


# Version/build metadata.
p = root / "app" / "Info.plist"
s = p.read_text()
s = must_replace(s, "<string>1.21.0</string>", "<string>1.22.0</string>", "Info.plist version")
s = must_replace(s, "<string>22</string>", "<string>23</string>", "Info.plist build")
p.write_text(s)

p = root / "Build-CI.sh"
s = p.read_text()
s = s.replace("Replyzen-update-1.21.zip", "Replyzen-update-1.22.zip")
s = s.replace(
    '"notes": "Replyzen 1.21: robustere PDF-Übernahme aus Outlook über direkte AX-Datei-URLs und automatisches Materialisieren des Anhangs; erweiterte Outlook-Temp-Suche."',
    '"notes": "Replyzen 1.22: neuer Absage-Button direkt im Outlook-Overlay. Ein Klick erkennt automatisch die Sprache der Mail, erstellt eine freundliche knappe Absage und setzt sie direkt in einen Outlook-Antwortentwurf ein; gesendet wird weiterhin nur manuell."'
)
p.write_text(s)
