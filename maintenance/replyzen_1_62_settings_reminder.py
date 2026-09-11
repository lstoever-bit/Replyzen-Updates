#!/usr/bin/env python3
"""ReplyZen 1.62: move transfer preview into gear settings and default reminder to tomorrow."""
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
if info.get("CFBundleShortVersionString") == "1.62.0" and str(info.get("CFBundleVersion")) == "63":
    required = [app / "ReminderDay.swift", app / "WorkspaceComponents.swift", app / "MailWorkspaceView.swift"]
    if not all(path.exists() for path in required):
        raise SystemExit("ReplyZen reports 1.62 but required files are missing")
    print("ReplyZen 1.62 migration already applied")
    raise SystemExit(0)
if info.get("CFBundleShortVersionString") != "1.61.0" or str(info.get("CFBundleVersion")) != "62":
    raise SystemExit("Unexpected ReplyZen source version; refusing to modify")

# Local-calendar helper. The existing fut.io BCC contract continues to use weekday codes.
(app / "ReminderDay.swift").write_text('''import Foundation

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
''', encoding="utf-8")

# Dynamic default in AppState; preview preference remains persisted and defaults false when absent.
state_path = app / "AppState.swift"
state = state_path.read_text(encoding="utf-8")
state = replace_once(state, '@Published var reminderDay: String = "wed"', '@Published var reminderDay: String = ReminderDay.nextCode()', "dynamic reminder default")
state_path.write_text(state, encoding="utf-8")

# Remove preview checkbox from the normal mail workflow. When reminder is switched on,
# select tomorrow again while keeping the existing manual weekday/time controls intact.
workspace_path = app / "MailWorkspaceView.swift"
workspace = workspace_path.read_text(encoding="utf-8")
workspace = replace_once(
    workspace,
'''                    transferPreviewControl
                        .fixedSize(horizontal: false, vertical: true)
                    reminderControl
''',
'''                    reminderControl
''',
    "remove main preview row",
)
start = workspace.find('    private var transferPreviewControl: some View {')
end = workspace.find('    private var reminderControl: some View {', start)
if start < 0 or end < 0:
    raise RuntimeError("transfer preview control block not found")
workspace = workspace[:start] + workspace[end:]
workspace = replace_once(
    workspace,
'''        .font(.system(size: 12)).frame(minHeight: 24)
        .onChange(of: state.reminderEnabled) { enabled in if !enabled { showsReminder = false } }
''',
'''        .font(.system(size: 12)).frame(minHeight: 24)
        .onChange(of: state.reminderEnabled) { enabled in
            if enabled {
                state.reminderDay = ReminderDay.nextCode()
            } else {
                showsReminder = false
            }
        }
''',
    "reminder enable defaults to tomorrow",
)
workspace_path.write_text(workspace, encoding="utf-8")

# Put the exact same preview setting behind the existing gear popover.
chrome_path = app / "WorkspaceComponents.swift"
chrome = chrome_path.read_text(encoding="utf-8")
chrome = replace_once(
    chrome,
'''                    InterfaceLanguagePicker()
                    Divider()
                    Text(L10n.tr("Öffnen in Outlook: ⌃⌥R"))
''',
'''                    InterfaceLanguagePicker()
                    Toggle(L10n.tr("Übergabe vor ChatGPT anzeigen"), isOn: $state.previewBeforeChatGPT)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .help(L10n.tr("Zeigt vor dem Senden genau die Daten, die an ChatGPT übergeben werden."))
                    Divider()
                    Text(L10n.tr("Öffnen in Outlook: ⌃⌥R"))
''',
    "gear preview setting",
)
chrome_path.write_text(chrome, encoding="utf-8")

# Every newly opened mail workflow starts with tomorrow, independent of the last manual choice.
delegate_path = app / "AppDelegate.swift"
delegate = delegate_path.read_text(encoding="utf-8")
delegate = replace_once(
    delegate,
'''        state.instructionHTML = ""
        state.reminderEnabled = false
        state.reminderTime = "06:00"
''',
'''        state.instructionHTML = ""
        state.reminderEnabled = false
        state.reminderDay = ReminderDay.nextCode()
        state.reminderTime = "06:00"
''',
    "reset reminder to tomorrow on workspace open",
)
delegate_path.write_text(delegate, encoding="utf-8")

# Version.
info["CFBundleShortVersionString"] = "1.62.0"
info["CFBundleVersion"] = "63"
info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=False))

# Focused tests for date rollover and source placement.
(repo / "tests" / "ReminderDayTests.swift").write_text('''import Foundation

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
''', encoding="utf-8")

run_tests_path = repo / "tests" / "run-tests.sh"
run_tests = run_tests_path.read_text(encoding="utf-8")
needle = 'python3 "$ROOT/tests/test_source_contracts.py" "$SOURCE"\n'
run_tests = replace_once(
    run_tests,
    needle,
    needle + 'swiftc -parse-as-library "$SOURCE/app/ReminderDay.swift" "$ROOT/tests/ReminderDayTests.swift" -o "$TMP/reminder-day-tests"\n"$TMP/reminder-day-tests"\n',
    "reminder test runner",
)
run_tests_path.write_text(run_tests, encoding="utf-8")

contracts_path = repo / "tests" / "test_source_contracts.py"
contracts = contracts_path.read_text(encoding="utf-8")
contracts = contracts.replace('self.assertEqual(info["CFBundleShortVersionString"], "1.61.0")', 'self.assertEqual(info["CFBundleShortVersionString"], "1.62.0")')
contracts = contracts.replace('self.assertEqual(info["CFBundleVersion"], "62")', 'self.assertEqual(info["CFBundleVersion"], "63")')
contracts = contracts.replace('        self.assertIn("Übergabe vor ChatGPT anzeigen", workspace)\n', '        self.assertNotIn("Übergabe vor ChatGPT anzeigen", workspace)\n        chrome = self.read("WorkspaceComponents.swift")\n        self.assertIn("Übergabe vor ChatGPT anzeigen", chrome)\n        self.assertIn("$state.previewBeforeChatGPT", chrome)\n')
insert_marker = '    def test_overlay_restores_after_workspace_close(self):\n'
new_test = '''    def test_preview_setting_and_next_day_reminder(self):
        state = self.read("AppState.swift")
        workspace = self.read("MailWorkspaceView.swift")
        chrome = self.read("WorkspaceComponents.swift")
        delegate = self.read("AppDelegate.swift")
        reminder = self.read("ReminderDay.swift")
        self.assertNotIn("transferPreviewControl", workspace)
        self.assertNotIn("Übergabe vor ChatGPT anzeigen", workspace)
        self.assertIn("Übergabe vor ChatGPT anzeigen", chrome)
        self.assertIn("$state.previewBeforeChatGPT", chrome)
        self.assertIn('UserDefaults.standard.bool(forKey: "ReplyZen.PreviewBeforeChatGPT")', state)
        self.assertIn("ReminderDay.nextCode()", state)
        self.assertIn("state.reminderDay = ReminderDay.nextCode()", delegate)
        self.assertIn("state.reminderDay = ReminderDay.nextCode()", workspace)
        self.assertIn("calendar.date(byAdding: .day, value: 1", reminder)
        self.assertIn("Picker(L10n.tr(\"Tag\"), selection: $state.reminderDay)", workspace)
        self.assertIn("Picker(L10n.tr(\"Uhrzeit\"), selection: $state.reminderTime)", workspace)
        self.assertIn("private func reminderBCCAddress()", delegate)

'''
if insert_marker not in contracts:
    raise RuntimeError("source contract insertion marker missing")
contracts = contracts.replace(insert_marker, new_test + insert_marker, 1)
contracts_path.write_text(contracts, encoding="utf-8")

verify_path = repo / "tests" / "verify_update.py"
verify = verify_path.read_text(encoding="utf-8")
verify = verify.replace("manifest['version'] == '1.61.0' and manifest['build'] == 62", "manifest['version'] == '1.62.0' and manifest['build'] == 63")
verify = verify.replace("manifest['download_url'] == 'Replyzen-update-1.61.zip'", "manifest['download_url'] == 'Replyzen-update-1.62.zip'")
verify = verify.replace("PASS: 1.61 version/build", "PASS: 1.62 version/build")
verify_path.write_text(verify, encoding="utf-8")

notes_de = "ReplyZen 1.62: Die Option „Übergabe vor ChatGPT anzeigen“ wurde aus dem normalen Mail-Workflow in die Einstellungen hinter dem Zahnrad verschoben; die Vorschaufunktion bleibt unverändert und ist standardmäßig deaktiviert. Follow-up/Reminder wählt beim Start eines neuen Mail-Vorgangs und beim Aktivieren automatisch den nächsten lokalen Kalendertag aus. Wochenend-, Monats- und Jahreswechsel werden korrekt berücksichtigt; Tag und Uhrzeit bleiben manuell änderbar und die bestehende fut.io-BCC-Logik bleibt unverändert."
notes_en = "ReplyZen 1.62: The “Show handoff before ChatGPT” option has moved out of the normal mail workflow into the settings behind the gear; preview behavior is unchanged and remains disabled by default. Follow-up/Reminder now defaults to the next local calendar day when a new mail flow starts and when the reminder is enabled. Weekend, month and year transitions are handled correctly; day and time remain editable and the existing fut.io BCC behavior is unchanged."
notes_es = "ReplyZen 1.62: La opción «Mostrar la transferencia antes de ChatGPT» se ha movido del flujo normal de correo a los ajustes detrás del icono de engranaje; la vista previa no cambia y sigue desactivada de forma predeterminada. Follow-up/Reminder ahora selecciona por defecto el siguiente día natural local al iniciar un nuevo flujo de correo y al activar el recordatorio. Los cambios de fin de semana, mes y año se gestionan correctamente; el día y la hora siguen siendo editables y la lógica BCC de fut.io no cambia."
(root / "Release-notes.txt").write_text(notes_de + "\n", encoding="utf-8")
(root / "Release-notes.localized.json").write_text(json.dumps({"de": notes_de, "en-US": notes_en, "es": notes_es}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

print("Migrated ReplyZen to 1.62.0 / build 63")
