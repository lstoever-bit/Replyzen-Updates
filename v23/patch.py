from pathlib import Path

root = Path(__import__('sys').argv[1])

# CalendarManager: make Europe/Berlin the canonical calendar timezone.
p = root / 'app' / 'CalendarManager.swift'
s = p.read_text()
s = s.replace('final class CalendarManager {\n    static let targetEmail = "lennard@minubo.com"',
              'final class CalendarManager {\n    static let targetEmail = "lennard@minubo.com"\n    static let eventTimeZoneIdentifier = "Europe/Berlin"\n    static let eventTimeZone = TimeZone(identifier: eventTimeZoneIdentifier) ?? TimeZone(secondsFromGMT: 3600)!')
s = s.replace('let timezone = TimeZone.current.identifier', 'let timezone = Self.eventTimeZoneIdentifier')
p.write_text(s)

# OpenAI calendar extraction: resolve all times against Central European time.
p = root / 'app' / 'OpenAIClient.swift'
s = p.read_text()
s = s.replace('''        let now = ISO8601DateFormatter().string(from: Date())\n        let timezone = TimeZone.current.identifier\n        let titleLanguage = language == .german ? "German" : "US English"''',
'''        let nowFormatter = ISO8601DateFormatter()\n        nowFormatter.timeZone = CalendarManager.eventTimeZone\n        let now = nowFormatter.string(from: Date())\n        let timezone = CalendarManager.eventTimeZoneIdentifier\n        let titleLanguage = language == .german ? "German" : "US English"''')
s = s.replace('''            "Do not invent a date, time, attendee, location, or commitment.",\n            "Current time is \\(now). The user's local timezone is \\(timezone). Resolve explicit relative dates such as tomorrow using this context."''',
'''            "Do not invent a date, time, attendee, location, or commitment.",\n            "Default calendar timezone is Europe/Berlin (Central European time: CET/CEST). Interpret date and time references in this timezone by default. If the email explicitly states another timezone, convert the resulting event time to Europe/Berlin.",\n            "Current time in \\(timezone) is \\(now). Resolve explicit relative dates such as tomorrow using this context."''')
p.write_text(s)

# DatePickers and displayed confirmation should always use Central European time,
# independent of the Mac's current timezone/location.
p = root / 'app' / 'OverlayView.swift'
s = p.read_text()
s = s.replace('''                    DatePicker("", selection: $state.calendarStart, displayedComponents: [.date, .hourAndMinute])\n                        .labelsHidden()''',
'''                    DatePicker("", selection: $state.calendarStart, displayedComponents: [.date, .hourAndMinute])\n                        .labelsHidden()\n                        .environment(\\.timeZone, CalendarManager.eventTimeZone)''')
s = s.replace('''                    DatePicker("", selection: $state.calendarEnd, displayedComponents: [.date, .hourAndMinute])\n                        .labelsHidden()''',
'''                    DatePicker("", selection: $state.calendarEnd, displayedComponents: [.date, .hourAndMinute])\n                        .labelsHidden()\n                        .environment(\\.timeZone, CalendarManager.eventTimeZone)''')
# Add a clear timezone hint next to the date controls.
s = s.replace('''                Spacer()\n            }\n\n            VStack(alignment: .leading, spacing: 8) {\n                HStack(spacing: 6) {\n                    Image(systemName: "g.circle.fill")''',
'''                Spacer()\n            }\n\n            Text("Zeitzone: CET / Europe-Berlin")\n                .font(.caption)\n                .foregroundStyle(.secondary)\n\n            VStack(alignment: .leading, spacing: 8) {\n                HStack(spacing: 6) {\n                    Image(systemName: "g.circle.fill")''', 1)
p.write_text(s)

# AppDelegate fallback and success display should use Europe/Berlin too.
p = root / 'app' / 'AppDelegate.swift'
s = p.read_text()
s = s.replace('''                    formatter.locale = Locale(identifier: "de_DE")\n                    formatter.dateStyle = .medium''',
'''                    formatter.locale = Locale(identifier: "de_DE")\n                    formatter.timeZone = CalendarManager.eventTimeZone\n                    formatter.dateStyle = .medium''')
s = s.replace('''    private func nextRoundedHour() -> Date {\n        let calendar = Calendar.current\n        let now = Date().addingTimeInterval(60 * 60)''',
'''    private func nextRoundedHour() -> Date {\n        var calendar = Calendar(identifier: .gregorian)\n        calendar.timeZone = CalendarManager.eventTimeZone\n        let now = Date().addingTimeInterval(60 * 60)''')
p.write_text(s)

# Version bump.
p = root / 'app' / 'Info.plist'
s = p.read_text()
s = s.replace('<string>1.12.0</string>', '<string>1.13.0</string>', 1)
s = s.replace('<string>13</string>', '<string>14</string>', 1)
p.write_text(s)

# Version-specific package and update notes.
p = root / 'Build-CI.sh'
s = p.read_text()
s = s.replace('Replyzen-update-1.12.zip', 'Replyzen-update-1.13.zip')
s = s.replace('Replyzen 1.12: Google-Schlüsselbundzugriff auf einen einzigen Eintrag konsolidiert; wiederholte macOS-Zugriffsabfragen werden nach einmaliger Migration vermieden.',
              'Replyzen 1.13: Termine verwenden standardmäßig immer die Zeitzone Europe/Berlin (CET/CEST), unabhängig von der aktuellen Mac-Zeitzone.')
p.write_text(s)
