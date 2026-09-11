import Foundation

enum ReminderDay {
    static func nextDate(from date: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: date) ?? date
    }

    static func code(for date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.weekday, from: date) {
        case 1: return "sun"
        case 2: return "mon"
        case 3: return "tues"
        case 4: return "wed"
        case 5: return "thurs"
        case 6: return "fri"
        case 7: return "sat"
        default: return "mon"
        }
    }

    static func nextCode(from date: Date = Date(), calendar: Calendar = .current) -> String {
        code(for: nextDate(from: date, calendar: calendar), calendar: calendar)
    }
}
