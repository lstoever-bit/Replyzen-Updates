#!/usr/bin/env python3
"""ReplyZen 1.67: wait for Outlook Forward body/attachments to settle before inserting text."""
from pathlib import Path
import json
import plistlib
import sys

root = Path(sys.argv[1])
repo = root.parent
app = root / "app"


def replace_once(text: str, before: str, after: str, label: str) -> str:
    count = text.count(before)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}")
    return text.replace(before, after, 1)


info_path = app / "Info.plist"
info = plistlib.loads(info_path.read_bytes())

if info.get("CFBundleShortVersionString") == "1.67.0" and str(info.get("CFBundleVersion")) == "68":
    delegate = (app / "AppDelegate.swift").read_text(encoding="utf-8")
    outlook = (app / "OutlookAccessibility.swift").read_text(encoding="utf-8")
    required_delegate = [
        "let sourceHasAttachments = outlook.hasVisibleForwardAttachments(from: snapshot)",
        "forwardComposerStabilityFingerprint()",
        "sourceHasAttachments: sourceHasAttachments",
        "requiredStablePasses = sourceHasAttachments ? 8 : 3",
        "maxAttempts = sourceHasAttachments ? 48 : 24",
    ]
    required_outlook = [
        "func hasVisibleForwardAttachments(from snapshot: Snapshot) -> Bool",
        "func forwardComposerStabilityFingerprint() -> String?",
        "containsForwardAttachmentMarker(in root: AXUIElement)",
    ]
    if not all(token in delegate for token in required_delegate):
        raise SystemExit("ReplyZen reports 1.67 but the Forward attachment/body stability fix is incomplete")
    if not all(token in outlook for token in required_outlook):
        raise SystemExit("ReplyZen reports 1.67 but the Outlook Forward stability helpers are incomplete")
    print("ReplyZen 1.67 migration already applied")
    raise SystemExit(0)

if info.get("CFBundleShortVersionString") != "1.66.0" or str(info.get("CFBundleVersion")) != "67":
    raise SystemExit("Unexpected ReplyZen source version; refusing to modify")

# Outlook owns native Forward creation, including the original body and attachments.
# Add read-only readiness helpers so ReplyZen can wait until that native UI stops
# changing before it pastes its own text above the forwarded message.
outlook_path = app / "OutlookAccessibility.swift"
outlook = outlook_path.read_text(encoding="utf-8")
needle = '''    func setComposeBCCValue(_ bcc: String) -> Bool {
'''
helpers = '''    func hasVisibleForwardAttachments(from snapshot: Snapshot) -> Bool {
        for window in snapshot.windows {
            if containsForwardAttachmentMarker(in: window) { return true }
        }
        return false
    }

    func forwardComposerStabilityFingerprint() -> String? {
        guard let window = focusedOutlookWindow(), looksLikeComposeWindow(window) else { return nil }

        let readableRoles: Set<String> = [
            "AXStaticText", "AXTextArea", "AXTextField", "AXWebArea",
            "AXButton", "AXLink", "AXGroup"
        ]
        let attributes: [CFString] = [
            kAXValueAttribute as CFString,
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString,
            "AXFilename" as CFString,
            "AXRoleDescription" as CFString
        ]

        var lines: [String] = []
        var stack: [AXUIElement] = [window]
        var visited = 0
        while let element = stack.popLast(), visited < 16_000 {
            visited += 1
            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            if readableRoles.contains(role) {
                for attribute in attributes {
                    if let value = stringLikeAttribute(attribute, from: element) {
                        let cleanedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleanedValue.isEmpty { lines.append(cleanedValue) }
                    }
                }
            }
            for child in children(of: element).reversed() { stack.append(child) }
        }

        let cleaned = cleanup(lines.joined(separator: "\n"))
        guard cleaned.count > 20 else { return nil }
        // A bounded fingerprint is enough to detect Outlook rebuilding the Forward
        // body or adding/removing attachment controls without retaining huge threads.
        return String(cleaned.prefix(24_000))
    }

    private func containsForwardAttachmentMarker(in root: AXUIElement) -> Bool {
        let attachmentWords = [
            "attachment", "attachments", "anlage", "anlagen", "anhang", "anhange",
            "adjunto", "adjuntos", "archivo adjunto"
        ]
        let attachmentExtensions: Set<String> = [
            "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv", "txt",
            "rtf", "zip", "rar", "7z", "eml", "msg", "ics", "png", "jpg", "jpeg",
            "gif", "tif", "tiff", "heic", "webp", "svg", "stl", "step", "stp",
            "dwg", "dxf", "ai", "psd", "indd", "json", "xml", "pages", "numbers",
            "key", "md", "log"
        ]
        let attributes: [CFString] = [
            "AXFilename" as CFString,
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString,
            kAXValueAttribute as CFString
        ]

        var stack: [AXUIElement] = [root]
        var visited = 0
        while let element = stack.popLast(), visited < 14_000 {
            visited += 1
            for attribute in attributes {
                guard let raw = stringLikeAttribute(attribute, from: element) else { continue }
                let normalized = raw
                    .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
                    .lowercased()
                if attachmentWords.contains(where: { normalized.contains($0) }) {
                    return true
                }
                if attachmentExtensions.contains(where: { normalized.contains("." + $0) }) {
                    return true
                }
            }
            for child in children(of: element).reversed() { stack.append(child) }
        }
        return false
    }

'''
outlook = replace_once(outlook, needle, helpers + needle, "Forward stability helpers")
outlook_path.write_text(outlook, encoding="utf-8")

delegate_path = app / "AppDelegate.swift"
delegate = delegate_path.read_text(encoding="utf-8")

delegate = replace_once(
    delegate,
'''        let html = state.replyHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        guard outlook.isTrusted() else {
''',
'''        let html = state.replyHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let sourceHasAttachments = outlook.hasVisibleForwardAttachments(from: snapshot)

        guard outlook.isTrusted() else {
''',
    "Forward source attachment detection",
)

delegate = replace_once(
    delegate,
'''                self.populateForwardDraft(body: body, html: html, snapshot: snapshot, attempt: 0)
''',
'''                self.populateForwardDraft(
                    body: body,
                    html: html,
                    snapshot: snapshot,
                    sourceHasAttachments: sourceHasAttachments,
                    lastStabilityFingerprint: nil,
                    stablePasses: 0,
                    attempt: 0
                )
''',
    "Forward initial populate call",
)

delegate = replace_once(
    delegate,
'''    private func populateForwardDraft(body: String, html: String, snapshot: OutlookAccessibility.Snapshot, attempt: Int) {
''',
'''    private func populateForwardDraft(
        body: String,
        html: String,
        snapshot: OutlookAccessibility.Snapshot,
        sourceHasAttachments: Bool,
        lastStabilityFingerprint: String?,
        stablePasses: Int,
        attempt: Int
    ) {
''',
    "Forward populate signature",
)

delegate = replace_once(
    delegate,
'''                if attempt < 12 {
                    self.populateForwardDraft(body: body, html: html, snapshot: snapshot, attempt: attempt + 1)
                    return
                }
''',
'''                let maxAttempts = sourceHasAttachments ? 48 : 24
                if attempt < maxAttempts {
                    self.populateForwardDraft(
                        body: body,
                        html: html,
                        snapshot: snapshot,
                        sourceHasAttachments: sourceHasAttachments,
                        lastStabilityFingerprint: lastStabilityFingerprint,
                        stablePasses: stablePasses,
                        attempt: attempt + 1
                    )
                    return
                }
''',
    "Forward composer-open retry",
)

stability_needle = '''            if let reminder = self.reminderBCCAddress() {
'''
stability_block = '''            // Outlook builds a native Forward in multiple asynchronous stages.
            // With attachments it can recreate the message body after the composer
            // first appears. Wait until the visible compose tree (body + attachment
            // controls) remains unchanged for several polls before inserting text.
            let requiredStablePasses = sourceHasAttachments ? 8 : 3
            let maxAttempts = sourceHasAttachments ? 48 : 24
            let nilGraceAttempts = sourceHasAttachments ? 16 : 4
            if let currentFingerprint = self.outlook.forwardComposerStabilityFingerprint() {
                let nextStablePasses = currentFingerprint == lastStabilityFingerprint
                    ? stablePasses + 1
                    : 0
                if nextStablePasses < requiredStablePasses, attempt < maxAttempts {
                    self.populateForwardDraft(
                        body: body,
                        html: html,
                        snapshot: snapshot,
                        sourceHasAttachments: sourceHasAttachments,
                        lastStabilityFingerprint: currentFingerprint,
                        stablePasses: nextStablePasses,
                        attempt: attempt + 1
                    )
                    return
                }
            } else if attempt < nilGraceAttempts {
                self.populateForwardDraft(
                    body: body,
                    html: html,
                    snapshot: snapshot,
                    sourceHasAttachments: sourceHasAttachments,
                    lastStabilityFingerprint: nil,
                    stablePasses: 0,
                    attempt: attempt + 1
                )
                return
            }

'''
# Insert only inside populateForwardDraft by splitting around that function.
start = delegate.index("    private func populateForwardDraft(")
end = delegate.index("    private func insertNewMail() {", start)
forward_block = delegate[start:end]
forward_block = replace_once(forward_block, stability_needle, stability_block + stability_needle, "Forward stability gate")

forward_block = replace_once(
    forward_block,
'''            if attempt < 12 {
                self.populateForwardDraft(body: body, html: html, snapshot: snapshot, attempt: attempt + 1)
                return
            }
''',
'''            let finalMaxAttempts = sourceHasAttachments ? 48 : 24
            if attempt < finalMaxAttempts {
                self.populateForwardDraft(
                    body: body,
                    html: html,
                    snapshot: snapshot,
                    sourceHasAttachments: sourceHasAttachments,
                    lastStabilityFingerprint: lastStabilityFingerprint,
                    stablePasses: stablePasses,
                    attempt: attempt + 1
                )
                return
            }
''',
    "Forward body-focus retry",
)
delegate = delegate[:start] + forward_block + delegate[end:]
delegate_path.write_text(delegate, encoding="utf-8")

# Version.
info["CFBundleShortVersionString"] = "1.67.0"
info["CFBundleVersion"] = "68"
info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=False))

# Source contracts: assert the attachment-safe sequencing and that ReplyZen never
# manually re-adds attachments or replaces the native Forward body.
contracts_path = repo / "tests" / "test_source_contracts.py"
contracts = contracts_path.read_text(encoding="utf-8")
contracts = contracts.replace('self.assertEqual(info["CFBundleShortVersionString"], "1.66.0")', 'self.assertEqual(info["CFBundleShortVersionString"], "1.67.0")')
contracts = contracts.replace('self.assertEqual(info["CFBundleVersion"], "67")', 'self.assertEqual(info["CFBundleVersion"], "68")')
start = contracts.index("    def test_forward_insertion_matches_reply_lifecycle(self):")
end = contracts.index("    def test_calendar_invite_reader(self):", start)
forward_test = '''    def test_forward_insertion_matches_reply_lifecycle(self):
        delegate = self.read("AppDelegate.swift")
        outlook = self.read("OutlookAccessibility.swift")
        matcher = self.read("OutlookReplyControlMatcher.swift")
        self.assertIn("func openForwardComposer(from snapshot: Snapshot)", outlook)
        self.assertIn("func hasOpenedForwardComposer(since snapshot: Snapshot)", outlook)
        self.assertIn("func hasVisibleForwardAttachments(from snapshot: Snapshot) -> Bool", outlook)
        self.assertIn("func forwardComposerStabilityFingerprint() -> String?", outlook)
        self.assertIn("containsForwardAttachmentMarker(in root: AXUIElement)", outlook)
        self.assertIn("OutlookReplyControlMatcher.forwardScore", outlook)
        self.assertIn("static func forwardScore(metadata: String)", matcher)
        forward = delegate[delegate.index("private func insertForwardDraft()") : delegate.index("private func insertNewMail()") ]
        self.assertIn("openForwardComposer(from: snapshot)", forward)
        self.assertIn("hasOpenedForwardComposer(since: snapshot)", forward)
        self.assertIn("let sourceHasAttachments = outlook.hasVisibleForwardAttachments(from: snapshot)", forward)
        self.assertIn("sourceHasAttachments: sourceHasAttachments", forward)
        self.assertIn("forwardComposerStabilityFingerprint()", forward)
        self.assertIn("requiredStablePasses = sourceHasAttachments ? 8 : 3", forward)
        self.assertIn("maxAttempts = sourceHasAttachments ? 48 : 24", forward)
        self.assertIn("nilGraceAttempts = sourceHasAttachments ? 16 : 4", forward)
        self.assertIn("lastStabilityFingerprint", forward)
        self.assertIn("stablePasses", forward)
        self.assertIn("self.keyboard.sendCommandJ()", forward)
        self.assertIn('let plain = body + "\\n\\n"', forward)
        self.assertIn('html + "<br><br>"', forward)
        self.assertIn("self.keyboard.sendCommandUp()", forward)
        self.assertNotIn("attachmentFileURLs(", forward)
        self.assertNotIn("materializeAttachment", forward)
        self.assertNotIn("setComposeBodyValue", forward)
        reply = delegate[delegate.index("private func insertReply()") : delegate.index("private func insertForwardDraft()") ]
        self.assertIn("openReplyComposer(replyAll: replyAll, from: snapshot)", reply)
        self.assertIn("hasOpenedReplyComposer(since: snapshot)", reply)

'''
contracts = contracts[:start] + forward_test + contracts[end:]
contracts_path.write_text(contracts, encoding="utf-8")

verify_path = repo / "tests" / "verify_update.py"
verify = verify_path.read_text(encoding="utf-8")
verify = verify.replace("manifest['version'] == '1.66.0' and manifest['build'] == 67", "manifest['version'] == '1.67.0' and manifest['build'] == 68")
verify = verify.replace("manifest['download_url'] == 'Replyzen-update-1.66.zip'", "manifest['download_url'] == 'Replyzen-update-1.67.zip'")
verify = verify.replace("PASS: 1.66 version/build", "PASS: 1.67 version/build")
verify_path.write_text(verify, encoding="utf-8")

notes_de = "ReplyZen 1.67: Weiterleitungen mit Anhängen warten jetzt, bis Outlook den nativen Forward-Body und die Anhangsoberfläche vollständig aufgebaut und stabilisiert hat. Erst danach fügt ReplyZen den erzeugten oder eingegebenen Text oben ein. Dadurch kann Outlook den Text beim nachträglichen Laden der Anhänge nicht mehr überschreiben. Original-Mail und Anhänge bleiben unverändert erhalten; Weiterleitungen ohne Anhang verwenden denselben Ablauf."
notes_en = "ReplyZen 1.67: Forwards with attachments now wait until Outlook has fully built and stabilized the native forwarded body and attachment UI before ReplyZen inserts the generated or entered text at the top. This prevents Outlook from overwriting the ReplyZen text while attachments finish loading. The original message and all native attachments remain unchanged; forwards without attachments use the same flow."
notes_es = "ReplyZen 1.67: Los reenvíos con archivos adjuntos ahora esperan a que Outlook termine de crear y estabilizar el cuerpo reenviado nativo y la interfaz de adjuntos antes de insertar arriba el texto generado o introducido en ReplyZen. Así Outlook ya no puede sobrescribir el texto mientras termina de cargar los adjuntos. El mensaje original y todos los adjuntos nativos permanecen sin cambios; los reenvíos sin adjuntos usan el mismo flujo."
(root / "Release-notes.txt").write_text(notes_de + "\n", encoding="utf-8")
(root / "Release-notes.localized.json").write_text(json.dumps({"de": notes_de, "en-US": notes_en, "es": notes_es}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

print("Migrated ReplyZen to 1.67.0 / build 68")
