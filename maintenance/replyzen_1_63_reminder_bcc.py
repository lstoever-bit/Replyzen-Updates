#!/usr/bin/env python3
"""ReplyZen 1.63: reliably commit reminder recipients into Outlook BCC."""
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
if info.get("CFBundleShortVersionString") == "1.63.0" and str(info.get("CFBundleVersion")) == "64":
    print("ReplyZen 1.63 migration already applied")
    raise SystemExit(0)
if info.get("CFBundleShortVersionString") != "1.62.0" or str(info.get("CFBundleVersion")) != "63":
    raise SystemExit("Unexpected ReplyZen source version; refusing to modify")

# 1) Reply fallback must also attempt BCC before body/subject fallback.
delegate_path = app / "AppDelegate.swift"
delegate = delegate_path.read_text(encoding="utf-8")
delegate = replace_once(
    delegate,
'''            if self.outlook.focusComposeBodyField() {
                if let reminder = self.reminderBCCAddress() {
                    _ = self.outlook.setComposeBCCValue(reminder)
                    _ = self.outlook.focusComposeBodyField()
                }
''',
'''            if let reminder = self.reminderBCCAddress() {
                _ = self.outlook.setComposeBCCValue(reminder)
            }

            if self.outlook.focusComposeBodyField() {
''',
    "reply BCC before body fallback",
)
delegate_path.write_text(delegate, encoding="utf-8")

# 2) Outlook recipient fields need a real commit action after AXValue is set.
outlook_path = app / "OutlookAccessibility.swift"
outlook = outlook_path.read_text(encoding="utf-8")
outlook = replace_once(
    outlook,
'''    func setComposeBCCValue(_ bcc: String) -> Bool {
        guard let window = focusedOutlookWindow() else { return false }
        if let element = composeBCCElement(in: window) {
            return setValue(bcc, on: element)
        }

        // Some Outlook layouts hide BCC until its small Bcc control is pressed.
        // Reveal it once, then resolve the actual BCC field again by accessibility metadata.
        if pressComposeControl(in: window, matching: ["bcc", "blind carbon", "blind copy", "blindkopie", "cco", "copia oculta"]) ,
           let refreshed = focusedOutlookWindow(),
           let element = composeBCCElement(in: refreshed) {
            return setValue(bcc, on: element)
        }
        return false
    }
''',
'''    func setComposeBCCValue(_ bcc: String) -> Bool {
        let recipient = bcc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recipient.isEmpty, let window = focusedOutlookWindow() else { return false }

        if let element = composeBCCElement(in: window) {
            return commitComposeRecipient(recipient, on: element)
        }

        // Some Outlook layouts hide BCC until its small Bcc control is pressed.
        // Revealing the row is asynchronous in Legacy Outlook, so allow the AX tree
        // a short moment to expose the recipient field before resolving it again.
        guard pressComposeControl(in: window, matching: ["bcc", "blind carbon", "blind copy", "blindkopie", "cco", "copia oculta"]) else {
            return false
        }
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.08)
            if let refreshed = focusedOutlookWindow(),
               let element = composeBCCElement(in: refreshed) {
                return commitComposeRecipient(recipient, on: element)
            }
        }
        return false
    }

    private func commitComposeRecipient(_ recipient: String, on element: AXUIElement) -> Bool {
        guard focus(element), setValue(recipient, on: element) else { return false }
        // Outlook recipient controls can visually show AXValue without adding it to
        // the native To/Cc/Bcc recipient model. Return commits the value as a token.
        postKey(code: 36)
        Thread.sleep(forTimeInterval: 0.06)
        return true
    }
''',
    "commit Outlook BCC recipient",
)
outlook_path.write_text(outlook, encoding="utf-8")

# Version and release notes.
info["CFBundleShortVersionString"] = "1.63.0"
info["CFBundleVersion"] = "64"
info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=False))

notes_de = "ReplyZen 1.63: Reminder-Adressen werden beim Erstellen eines Outlook-Entwurfs jetzt zuverlässig als BCC-Empfänger übernommen. Outlook erhält nach dem Setzen der fut.io-Adresse zusätzlich die notwendige Bestätigung des Empfängers; außerdem wird BCC nun auch im Legacy-Reply-Fallback gesetzt. Reply, Reply All, New Mail und Forward behalten ihre bestehende Einfügelogik bei."
notes_en = "ReplyZen 1.63: Reminder addresses are now reliably committed as BCC recipients when ReplyZen creates an Outlook draft. After setting the fut.io address, ReplyZen now performs the recipient confirmation Outlook requires, and BCC is also applied in the Legacy Outlook reply fallback. Existing Reply, Reply All, New Mail and Forward insertion behavior remains unchanged."
notes_es = "ReplyZen 1.63: Las direcciones de recordatorio ahora se confirman de forma fiable como destinatarios BCC al crear un borrador en Outlook. Después de establecer la dirección fut.io, ReplyZen realiza la confirmación de destinatario que requiere Outlook y BCC también se aplica en la ruta alternativa de respuesta de Outlook clásico. El comportamiento existente de Reply, Reply All, New Mail y Forward no cambia."
(root / "Release-notes.txt").write_text(notes_de + "\n", encoding="utf-8")
(root / "Release-notes.localized.json").write_text(json.dumps({"de": notes_de, "en-US": notes_en, "es": notes_es}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

contracts_path = repo / "tests" / "test_source_contracts.py"
contracts = contracts_path.read_text(encoding="utf-8")
contracts = contracts.replace('self.assertEqual(info["CFBundleShortVersionString"], "1.62.0")', 'self.assertEqual(info["CFBundleShortVersionString"], "1.63.0")')
contracts = contracts.replace('self.assertEqual(info["CFBundleVersion"], "63")', 'self.assertEqual(info["CFBundleVersion"], "64")')
marker = '    def test_overlay_restores_after_workspace_close(self):\n'
new_test = '''    def test_reminder_bcc_is_committed_in_all_compose_paths(self):
        delegate = self.read("AppDelegate.swift")
        outlook = self.read("OutlookAccessibility.swift")
        reply_start = delegate.index("private func populateReplyDraft")
        reply_end = delegate.index("private func insertForwardDraft", reply_start)
        reply = delegate[reply_start:reply_end]
        self.assertLess(reply.index("setComposeBCCValue(reminder)"), reply.index("focusComposeBodyField()"))
        self.assertIn("setComposeBCCValue(reminder)", delegate[delegate.index("private func populateForwardDraft"):delegate.index("private func insertNewMail")])
        self.assertIn("setComposeBCCValue(reminder)", delegate[delegate.index("private func populateNewMailDraft"):delegate.index("private func finishNewMailInsertion")])
        self.assertIn("private func commitComposeRecipient", outlook)
        commit = outlook[outlook.index("private func commitComposeRecipient"):outlook.index("func setComposeSubjectValue")]
        self.assertIn("focus(element)", commit)
        self.assertIn("setValue(recipient, on: element)", commit)
        self.assertIn("postKey(code: 36)", commit)
        bcc = outlook[outlook.index("func setComposeBCCValue"):outlook.index("func setComposeSubjectValue")]
        self.assertIn("for _ in 0..<3", bcc)
        self.assertIn("Thread.sleep(forTimeInterval: 0.08)", bcc)

'''
if marker not in contracts:
    raise RuntimeError("test insertion marker missing")
contracts = contracts.replace(marker, new_test + marker, 1)
contracts_path.write_text(contracts, encoding="utf-8")

verify_path = repo / "tests" / "verify_update.py"
verify = verify_path.read_text(encoding="utf-8")
verify = verify.replace("manifest['version'] == '1.62.0' and manifest['build'] == 63", "manifest['version'] == '1.63.0' and manifest['build'] == 64")
verify = verify.replace("manifest['download_url'] == 'Replyzen-update-1.62.zip'", "manifest['download_url'] == 'Replyzen-update-1.63.zip'")
verify = verify.replace("PASS: 1.62 version/build", "PASS: 1.63 version/build")
verify_path.write_text(verify, encoding="utf-8")

print("Migrated ReplyZen to 1.63.0 / build 64")
