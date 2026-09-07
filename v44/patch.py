from pathlib import Path
import sys

root = Path(sys.argv[1])


def replace_once(path, old, new, label):
    text = path.read_text()
    if old not in text:
        raise SystemExit(f"{label} not found")
    path.write_text(text.replace(old, new, 1))

# AppState: FUT default reminder time is 06:00.
p = root / "app" / "AppState.swift"
replace_once(
    p,
    '    @Published var reminderTime: String = "12:00"\n',
    '    @Published var reminderTime: String = "06:00"\n',
    "AppState reminder default time",
)

# Overlay: use FUT weekday spellings, zero-padded dropdown display, and compact
# address syntax without a colon. Omit 0600 because 06:00 is the chosen default.
p = root / "app" / "OverlayView.swift"
replace_once(
    p,
    '''    private var reminderDays: [(label: String, code: String)] {\n        [("Mo", "mon"), ("Di", "tue"), ("Mi", "wed"), ("Do", "thu"), ("Fr", "fri"), ("Sa", "sat"), ("So", "sun")]\n    }\n\n    private var reminderTimes: [String] {\n        (0...48).map { slot in\n            if slot == 48 { return "24:00" }\n            let hour = slot / 2\n            let minute = slot % 2 == 0 ? "00" : "30"\n            return "\\(hour):\\(minute)"\n        }\n    }\n\n    private var reminderAddress: String {\n        "\\(state.reminderDay)\\(state.reminderTime)@fut.io"\n    }\n''',
    '''    private var reminderDays: [(label: String, code: String)] {\n        [("Mo", "mon"), ("Di", "tues"), ("Mi", "wed"), ("Do", "thurs"), ("Fr", "fri"), ("Sa", "sat"), ("So", "sun")]\n    }\n\n    private var reminderTimes: [String] {\n        (0...48).map { slot in\n            if slot == 48 { return "24:00" }\n            let hour = slot / 2\n            let minute = slot % 2 == 0 ? 0 : 30\n            return String(format: "%02d:%02d", hour, minute)\n        }\n    }\n\n    private var reminderAddress: String {\n        let compactTime = state.reminderTime.replacingOccurrences(of: ":", with: "")\n        if compactTime == "0600" {\n            return "\\(state.reminderDay)@fut.io"\n        }\n        return "\\(state.reminderDay)\\(compactTime)@fut.io"\n    }\n''',
    "Overlay FUT reminder formats",
)

# AppDelegate: reset every fresh Mail workspace to 06:00 and generate the same
# BCC address shown in the UI.
p = root / "app" / "AppDelegate.swift"
replace_once(
    p,
    '        state.reminderEnabled = false\n',
    '        state.reminderEnabled = false\n        state.reminderTime = "06:00"\n',
    "AppDelegate reminder default reset",
)
replace_once(
    p,
    '''    private func reminderBCCAddress() -> String? {\n        guard state.reminderEnabled else { return nil }\n        let day = state.reminderDay.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()\n        let time = state.reminderTime.trimmingCharacters(in: .whitespacesAndNewlines)\n        guard ["mon", "tue", "wed", "thu", "fri", "sat", "sun"].contains(day), !time.isEmpty else { return nil }\n        return "\\(day)\\(time)@fut.io"\n    }\n''',
    '''    private func reminderBCCAddress() -> String? {\n        guard state.reminderEnabled else { return nil }\n        let day = state.reminderDay.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()\n        let time = state.reminderTime.trimmingCharacters(in: .whitespacesAndNewlines)\n        guard ["mon", "tues", "wed", "thurs", "fri", "sat", "sun"].contains(day), !time.isEmpty else { return nil }\n\n        let compactTime = time.replacingOccurrences(of: ":", with: "")\n        guard compactTime.count == 4, compactTime.allSatisfy({ $0.isNumber }) else { return nil }\n        if compactTime == "0600" {\n            return "\\(day)@fut.io"\n        }\n        return "\\(day)\\(compactTime)@fut.io"\n    }\n''',
    "AppDelegate FUT BCC formatter",
)

# Version and release metadata.
p = root / "app" / "Info.plist"
text = p.read_text()
text = text.replace('<string>1.30.0</string>', '<string>1.31.0</string>', 1)
text = text.replace('<string>31</string>', '<string>32</string>', 1)
p.write_text(text)

p = root / "Build-CI.sh"
text = p.read_text()
text = text.replace('Replyzen-update-1.30.zip', 'Replyzen-update-1.31.zip')
text = text.replace(
    'Replyzen 1.30: Reply verwendet immer Reply All. Optionaler Reminder in der Mail Ansicht mit Mo bis So und Uhrzeit 0:00 bis 24:00; bei Aktivierung wird automatisch z. B. wed12:00@fut.io in BCC gesetzt. Das macOS Menüleisten Icon wird aus dem Replyzen App Logo als transparente Template Maske erzeugt, damit kein weißes Quadrat mehr erscheint.',
    'Replyzen 1.31: FollowUpThen Reminder verwendet kompakte fut.io Formate ohne Doppelpunkt, z. B. tues1100@fut.io. 06:00 ist Standard; bei 06:00 wird die Uhrzeit weggelassen, z. B. tues@fut.io. Das Zeit Dropdown startet bei 06:00.'
)
p.write_text(text)
