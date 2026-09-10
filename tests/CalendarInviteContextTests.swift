import Foundation

@main
struct CalendarInviteContextTests {
    static func main() {
        let german = [
            "Late Lunch Len & Bernd",
            "Christian Scholdei <scholdei@hyest.de>",
            "Erforderlich: lst@blprojects.de",
            "Donnerstag, 24. September 2026 um 17:00",
            "LUST AUF ITALIEN - Große Elbstraße 133, Hamburg",
            "Annehmen",
            "Mit Vorbehalt",
            "Ablehnen"
        ]
        precondition(OutlookCalendarItemContext.looksLikeMeetingInvite(lines: german))
        let germanContext = OutlookCalendarItemContext.contextText(lines: german)
        precondition(germanContext.hasPrefix("OUTLOOK ITEM TYPE: MEETING INVITATION"))
        precondition(germanContext.contains("Late Lunch Len & Bernd"))
        precondition(germanContext.contains("24. September 2026"))

        let english = [
            "Project Sync", "Required: Alex", "Tuesday, September 29, 2026 10:30 AM",
            "Accept", "Tentative", "Decline"
        ]
        precondition(OutlookCalendarItemContext.looksLikeMeetingInvite(lines: english))

        let spanish = [
            "Revisión del proyecto", "Obligatorio: Ana", "Aceptar", "Provisional", "Rechazar"
        ]
        precondition(OutlookCalendarItemContext.looksLikeMeetingInvite(lines: spanish))

        let compactGerman = ["Annehmen", "Erforderlich: Lennard", "Besprechung am Donnerstag"]
        precondition(OutlookCalendarItemContext.looksLikeMeetingInvite(lines: compactGerman))

        let regularMail = [
            "Hi Lennard,", "please accept the attached proposal when you have time.",
            "Best regards,", "Stefan"
        ]
        precondition(!OutlookCalendarItemContext.looksLikeMeetingInvite(lines: regularMail))

        let normalized = OutlookCalendarItemContext.normalizedLines([
            "  Project Sync  ", "Project Sync", "\nAccept\n", "Accept", "\u{00A0}Tentative\u{00A0}"
        ])
        precondition(normalized == ["Project Sync", "Accept", "Tentative"])

        print("PASS: native Outlook meeting invitations detected in German, US English and Spanish; normal mail rejected")
    }
}
