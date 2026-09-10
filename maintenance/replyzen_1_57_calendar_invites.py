#!/usr/bin/env python3
"""ReplyZen 1.57: allow calendar creation from native Outlook meeting invitations."""
from pathlib import Path
import json
import plistlib
import sys

root = Path(sys.argv[1])
app = root / "app"
info_path = app / "Info.plist"
info = plistlib.loads(info_path.read_bytes())

if info.get("CFBundleShortVersionString") == "1.57.0":
    outlook = (app / "OutlookAccessibility.swift").read_text(encoding="utf-8")
    delegate = (app / "AppDelegate.swift").read_text(encoding="utf-8")
    assert "func readCalendarContext(from snapshot: Snapshot)" in outlook
    assert "readCalendarContext(from: snapshot)" in delegate
    print("ReplyZen 1.57 calendar invite migration already applied")
    raise SystemExit(0)

if info.get("CFBundleShortVersionString") != "1.56.0" or str(info.get("CFBundleVersion")) != "57":
    raise SystemExit("Unexpected ReplyZen source version; refusing to modify")


def replace_once(text: str, before: str, after: str) -> str:
    count = text.count(before)
    if count != 1:
        raise RuntimeError(f"Expected exactly one source marker, found {count}: {before[:100]!r}")
    return text.replace(before, after, 1)

# Meeting invitations in Legacy Outlook are often native AX controls/static text,
# not an AXWebArea. Add a calendar-specific reader while keeping normal mail reads unchanged.
outlook_path = app / "OutlookAccessibility.swift"
outlook = outlook_path.read_text(encoding="utf-8")
insert_marker = "\n\n    func attachmentFilenames(from snapshot: Snapshot) -> [String] {"
calendar_reader = r'''

    /// Reads either a normal Outlook email body or a native Outlook meeting card.
    /// Calendar creation must use this instead of readMail(from:) because meeting
    /// invitations in Legacy Outlook frequently have no readable AXWebArea at all.
    func readCalendarContext(from snapshot: Snapshot) throws -> String {
        if let invite = readVisibleMeetingInvite(from: snapshot) {
            return invite
        }
        return try readMail(from: snapshot)
    }

    private func readVisibleMeetingInvite(from snapshot: Snapshot) -> String? {
        for window in snapshot.windows {
            let lines = collectCalendarNativeText(root: window, maxNodes: 20_000)
            guard OutlookCalendarItemContext.looksLikeMeetingInvite(lines: lines) else { continue }
            let text = OutlookCalendarItemContext.contextText(lines: lines)
            if text.count > 20 { return text }
        }
        return nil
    }

    private func collectCalendarNativeText(root: AXUIElement, maxNodes: Int) -> [String] {
        let readableRoles: Set<String> = [
            "AXStaticText", "AXTextArea", "AXTextField", "AXButton",
            "AXMenuButton", "AXLink", "AXCheckBox", "AXRadioButton"
        ]
        let attributes: [CFString] = [
            kAXValueAttribute as CFString,
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString,
            "AXPlaceholderValue" as CFString,
            "AXRoleDescription" as CFString
        ]
        var lines: [String] = []
        var stack: [AXUIElement] = [root]
        var visited = 0

        while let element = stack.popLast(), visited < maxNodes {
            visited += 1
            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            if readableRoles.contains(role) {
                for attribute in attributes {
                    if let value = stringLikeAttribute(attribute, from: element),
                       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lines.append(value)
                    }
                }
            }
            for child in children(of: element).reversed() { stack.append(child) }
        }
        return OutlookCalendarItemContext.normalizedLines(lines)
    }
'''
outlook = replace_once(outlook, insert_marker, calendar_reader + insert_marker)
outlook_path.write_text(outlook, encoding="utf-8")

# Only the calendar action changes reader. Reply/Reply All/Forward keep using readMail.
delegate_path = app / "AppDelegate.swift"
delegate = delegate_path.read_text(encoding="utf-8")
start = delegate.index("    private func createCalendarFromOverlay() {")
end = delegate.index("    private func quickDecline() {", start)
calendar_block = delegate[start:end]
if calendar_block.count("self.outlook.readMail(from: snapshot)") != 2:
    raise RuntimeError("Unexpected createCalendarFromOverlay read structure")
calendar_block = calendar_block.replace(
    "self.outlook.readMail(from: snapshot)",
    "self.outlook.readCalendarContext(from: snapshot)"
)
calendar_block = calendar_block.replace(
    'L10n.source("Die geöffnete Outlook-Mail konnte nicht gelesen werden.")',
    'L10n.source("Die geöffnete Outlook-Nachricht oder Termineinladung konnte nicht gelesen werden.")'
)
delegate = delegate[:start] + calendar_block + delegate[end:]
delegate_path.write_text(delegate, encoding="utf-8")

# Tell the model explicitly that the selected item can already be a scheduled invite.
client_path = app / "OpenAIClient.swift"
client = client_path.read_text(encoding="utf-8")
client = replace_once(
    client,
    '            "Create a calendar event suggestion from the email thread.",',
    '            "Create a calendar event suggestion from the selected Outlook item. The item may be a normal email thread or an Outlook meeting invitation.",'
)
client = replace_once(
    client,
    '            "Use a date/time only if one future appointment time is clearly agreed or clearly proposed in the thread. If several dates/times are possible or the timing is ambiguous, set start and end to null.",',
    '            "Use a date/time if one future appointment time is clearly agreed, clearly proposed, or explicitly scheduled in an Outlook meeting invitation. If several dates/times are possible or the timing is ambiguous, set start and end to null.",'
)
client = replace_once(
    client,
    '            input: "SELECTED OUTPUT LANGUAGE: \\(titleLanguage)\\n\\nEMAIL THREAD:\\n\\(String(mailText.prefix(30_000)))",',
    '            input: "SELECTED OUTPUT LANGUAGE: \\(titleLanguage)\\n\\nOUTLOOK ITEM CONTEXT:\\n\\(String(mailText.prefix(30_000)))",'
)
client_path.write_text(client, encoding="utf-8")

# Localize the calendar-specific error in all supported UI languages.
localization_path = app / "Resources" / "Localization.json"
localization = json.loads(localization_path.read_text(encoding="utf-8"))
key = "Die geöffnete Outlook-Nachricht oder Termineinladung konnte nicht gelesen werden."
localization[key] = {
    "de": key,
    "en-US": "The selected Outlook message or meeting invitation could not be read.",
    "es": "No se ha podido leer el mensaje o la invitación de reunión seleccionados en Outlook."
}
localization_path.write_text(json.dumps(localization, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

# Version and release notes.
info["CFBundleShortVersionString"] = "1.57.0"
info["CFBundleVersion"] = "58"
info_path.write_bytes(plistlib.dumps(info, sort_keys=False))

notes = {
    "de": "ReplyZen 1.57: Die Termin-Funktion erkennt jetzt auch echte Outlook-Termineinladungen, die nicht als normale Mail vorliegen. Meeting-Karten mit Annehmen/Mit Vorbehalt/Ablehnen werden direkt aus der nativen Outlook-Oberfläche gelesen; Betreff, Organisator, Datum, Uhrzeit und weitere sichtbare Termininformationen können so für den Kalendereintrag verwendet werden. Normale E-Mails funktionieren weiterhin wie bisher.",
    "en-US": "ReplyZen 1.57: Calendar creation now also supports native Outlook meeting invitations that are not exposed as normal email messages. Meeting cards with Accept/Tentative/Decline controls are read directly from Outlook's native interface so the subject, organizer, date, time, and other visible event details can be used for the calendar entry. Normal emails continue to work as before.",
    "es": "ReplyZen 1.57: La creación de eventos ahora también admite invitaciones de reunión nativas de Outlook que no se muestran como correos normales. Las tarjetas con Aceptar/Provisional/Rechazar se leen directamente de la interfaz nativa de Outlook para usar el asunto, organizador, fecha, hora y demás datos visibles del evento. Los correos normales siguen funcionando como antes."
}
(root / "Release-notes.localized.json").write_text(json.dumps(notes, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
(root / "Release-notes.txt").write_text(notes["de"] + "\n", encoding="utf-8")

print("Migrated ReplyZen to 1.57.0 / build 58: native Outlook meeting invitations supported")
