import Foundation

@main
struct ReminderDayTests {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        }

        precondition(ReminderDay.nextCode(from: date(2026, 9, 7), calendar: calendar) == "tues")
        precondition(ReminderDay.nextCode(from: date(2026, 9, 11), calendar: calendar) == "sat")
        precondition(ReminderDay.nextCode(from: date(2026, 9, 13), calendar: calendar) == "mon")

        let monthChange = calendar.dateComponents([.year, .month, .day], from: ReminderDay.nextDate(from: date(2027, 1, 31), calendar: calendar))
        precondition(monthChange.year == 2027 && monthChange.month == 2 && monthChange.day == 1)

        let yearChange = calendar.dateComponents([.year, .month, .day], from: ReminderDay.nextDate(from: date(2026, 12, 31), calendar: calendar))
        precondition(yearChange.year == 2027 && yearChange.month == 1 && yearChange.day == 1)

        print("PASS: next-day reminder handles weekdays, weekends, month and year rollovers")
    }
}
