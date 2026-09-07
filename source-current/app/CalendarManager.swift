import Foundation
import EventKit

struct CalendarOption: Identifiable, Equatable {
    let id: String
    let title: String
    let sourceTitle: String
}

final class CalendarManager {
    static let targetCalendarID = "lennard@minubo.com"
    static let targetCalendarName = "minubo"

    enum CalendarError: LocalizedError {
        case accessDenied
        case targetCalendarNotFound([String])
        case selectedCalendarNotFound
        case invalidDates
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "Replyzen braucht Kalenderzugriff. Bitte unter Systemeinstellungen → Datenschutz & Sicherheit → Kalender den Zugriff für Replyzen erlauben."
            case .targetCalendarNotFound(let available):
                let suffix = available.isEmpty ? "" : " Gefundene beschreibbare Kalender: \(available.joined(separator: ", "))."
                return "Das Google-Konto lennard@minubo.com ist auf diesem Mac nicht als Kalenderquelle verfügbar. Bitte das minubo-Google-Konto unter Systemeinstellungen → Internetaccounts hinzufügen und Kalender aktivieren." + suffix
            case .selectedCalendarNotFound:
                return "Der ausgewählte Kalender ist nicht mehr verfügbar. Bitte einen anderen Kalender wählen."
            case .invalidDates:
                return "Start- und Endzeit des Termins sind ungültig."
            case .saveFailed(let message):
                return "Der Termin konnte nicht gespeichert werden: \(message)"
            }
        }
    }

    private let store = EKEventStore()

    func loadCalendarOptions(completion: @escaping (Result<[CalendarOption], Error>) -> Void) {
        requestAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                completion(.failure(CalendarError.accessDenied))
                return
            }

            do {
                let calendars = try self.resolveMinuboCalendars()
                let options = calendars
                    .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                    .map { CalendarOption(id: $0.calendarIdentifier, title: $0.title, sourceTitle: $0.source.title) }
                completion(.success(options))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func createEvent(
        title: String,
        notes: String,
        start: Date,
        end: Date,
        calendarIdentifier: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard end > start else {
            completion(.failure(CalendarError.invalidDates))
            return
        }

        requestAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                completion(.failure(CalendarError.accessDenied))
                return
            }

            guard let calendar = self.store.calendar(withIdentifier: calendarIdentifier),
                  calendar.allowsContentModifications else {
                completion(.failure(CalendarError.selectedCalendarNotFound))
                return
            }

            do {
                let event = EKEvent(eventStore: self.store)
                event.calendar = calendar
                event.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                event.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
                event.startDate = start
                event.endDate = end
                try self.store.save(event, span: .thisEvent, commit: true)
                completion(.success(calendar.title))
            } catch {
                completion(.failure(CalendarError.saveFailed(error.localizedDescription)))
            }
        }
    }

    private func requestAccess(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, _ in completion(granted) }
        } else {
            store.requestAccess(to: .event) { granted, _ in completion(granted) }
        }
    }

    private func resolveMinuboCalendars() throws -> [EKCalendar] {
        let writable = store.calendars(for: .event).filter { $0.allowsContentModifications }
        let wantedEmail = Self.targetCalendarID.lowercased()
        let wantedName = Self.targetCalendarName.lowercased()

        func score(_ calendar: EKCalendar) -> Int {
            let title = calendar.title.lowercased()
            let source = calendar.source.title.lowercased()
            var value = 0
            if title == wantedEmail { value += 1000 }
            if source == wantedEmail { value += 1000 }
            if title.contains(wantedEmail) { value += 900 }
            if source.contains(wantedEmail) { value += 900 }
            if title == wantedName { value += 800 }
            if title.contains(wantedName) { value += 700 }
            if source.contains(wantedName) { value += 650 }
            if title.contains("lennard") { value += 150 }
            if source.contains("lennard") { value += 150 }
            return value
        }

        guard let anchor = writable
            .map({ ($0, score($0)) })
            .filter({ $0.1 > 0 })
            .max(by: { $0.1 < $1.1 })?.0 else {
            let available = writable.map { "\($0.title) [\($0.source.title)]" }.sorted()
            throw CalendarError.targetCalendarNotFound(available)
        }

        let sourceID = anchor.source.sourceIdentifier
        let sameAccount = writable.filter { $0.source.sourceIdentifier == sourceID }
        return sameAccount.isEmpty ? [anchor] : sameAccount
    }
}
