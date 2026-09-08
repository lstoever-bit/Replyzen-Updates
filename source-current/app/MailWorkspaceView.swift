import AppKit
import SwiftUI

/// Existing mode-switch behavior, separated from presentation for regression tests.
enum MailWorkspaceLogic {
    static func canGenerate(_ state: AppState) -> Bool {
        let hasInstruction = !state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch state.outputMode {
        case .newMail: return hasInstruction
        case .reply, .forward: return state.mailStatus == .available && hasInstruction
        case .calendar, .payment: return state.mailStatus == .available
        }
    }

    static func select(_ mode: AppState.OutputMode, in state: AppState) {
        guard state.outputMode != mode else { return }
        state.outputMode = mode
        let trimmed = state.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDefault = trimmed == "Kurz, freundlich und direkt antworten." ||
            trimmed == "Reply briefly, friendly and directly."
        switch mode {
        case .newMail, .forward:
            if isDefault {
                state.instruction = ""
                state.instructionHTML = ""
            }
            if mode == .newMail { state.newMailSubject = "" }
        case .reply:
            if trimmed.isEmpty {
                state.instruction = state.replyLanguage == .german
                    ? "Kurz, freundlich und direkt antworten."
                    : "Reply briefly, friendly and directly."
                state.instructionHTML = ""
            }
        case .calendar, .payment: break
        }
    }
}

struct MailWorkspaceView: View {
    @ObservedObject var state: AppState
    @State private var showsReminder = false
    private static let days: [(label: String, code: String)] = [
        ("Mo", "mon"), ("Di", "tues"), ("Mi", "wed"), ("Do", "thurs"),
        ("Fr", "fri"), ("Sa", "sat"), ("So", "sun")
    ]
    private static let times = (0...48).map { slot in
        String(format: "%02d:%02d", slot / 2, slot % 2 == 0 ? 0 : 30)
    }
    private var isMail: Bool {
        state.outputMode == .reply || state.outputMode == .newMail || state.outputMode == .forward
    }
    private var hasMail: Bool { state.mailStatus == .available }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if isMail {
                    modeRow
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Deine Anweisung").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        RichTextMailEditor(plainText: $state.instruction, html: $state.instructionHTML,
                                           height: nil, showsHTMLBadge: false)
                            .accessibilityLabel("Anweisung für den Mailentwurf")
                    }
                    .frame(maxHeight: .infinity)
                    optionsRow
                    reminderControl
                } else {
                    contextLabel
                    extractionCard
                    Spacer(minLength: 0)
                    if state.outputMode == .calendar { languageSelector }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            WorkspaceActionBar(
                secondaryTitle: "Schließen", primaryTitle: primaryTitle,
                hint: isMail ? "Versendet wird erst in Outlook." : "Vor dem Übernehmen prüfen.",
                disabled: !MailWorkspaceLogic.canGenerate(state),
                secondaryAction: { state.closeAction?() },
                primaryAction: { state.generateAction?() }
            )
        }
    }

    private var modeRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                if hasMail { modeButton(.reply, symbol: "arrowshape.turn.up.left") }
                modeButton(.newMail, symbol: "square.and.pencil")
                if hasMail { modeButton(.forward, symbol: "arrowshape.turn.up.right") }
            }
            .padding(3)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            Spacer(minLength: 4)
            contextLabel
        }
    }

    private func modeButton(_ mode: AppState.OutputMode, symbol: String) -> some View {
        Button { MailWorkspaceLogic.select(mode, in: state) } label: {
            Label(mode.displayName, systemImage: symbol).lineLimit(1)
        }
        .buttonStyle(WorkspaceChoiceStyle(selected: state.outputMode == mode))
        .accessibilityAddTraits(state.outputMode == mode ? .isSelected : [])
    }

    private var contextLabel: some View {
        HStack(spacing: 6) {
            if state.mailStatus == .loading {
                ProgressView().controlSize(.mini)
                Text("Lädt …")
            } else {
                Image(systemName: hasMail ? "checkmark.circle" : "info.circle")
                Text(hasMail ? "Mail erkannt" : "Ohne Mail-Kontext")
            }
            if !hasMail && state.mailStatus != .loading {
                Button { state.refreshMailAction?() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Outlook-Mail erneut lesen")
                    .accessibilityLabel("Outlook-Mail erneut lesen")
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).help(contextHelp)
    }

    private var contextHelp: String {
        if case .unavailable(let message) = state.mailStatus { return message }
        return hasMail ? "Die geöffnete Outlook-Mail dient als Kontext."
            : "Neue Mail ohne Kontext möglich. Für Reply oder Forward zuerst eine Outlook-Mail öffnen."
    }

    private var optionsRow: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Text("Ton").font(.caption).foregroundStyle(.secondary)
                Picker("Ton", selection: $state.replyTone) {
                    ForEach(ReplyTone.allCases) { tone in Text(tone.displayName).tag(tone) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 138)
                .accessibilityLabel("Ton des Mailentwurfs")
            }
            Toggle("Compact", isOn: $state.newMailCompact)
                .toggleStyle(.checkbox).help("So kurz wie möglich formulieren")
            Spacer(minLength: 6)
            languageSelector
        }
        .controlSize(.small)
    }

    private var languageSelector: some View {
        HStack(spacing: 2) {
            languageButton("DE", language: .german, title: "Deutsch")
            languageButton("EN", language: .usEnglish, title: "US English")
        }
        .padding(3)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain).accessibilityLabel("Ausgabesprache")
    }

    private func languageButton(_ label: String, language: AppState.ReplyLanguage, title: String) -> some View {
        Button(label) { state.replyLanguage = language }
            .buttonStyle(WorkspaceChoiceStyle(selected: state.replyLanguage == language))
            .help(title).accessibilityLabel(title)
            .accessibilityAddTraits(state.replyLanguage == language ? .isSelected : [])
    }

    private var reminderControl: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $state.reminderEnabled) { Label("Reminder", systemImage: "bell") }
                .toggleStyle(.checkbox).controlSize(.small)
            if state.reminderEnabled {
                Button { showsReminder.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(reminderSummary)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                }
                .buttonStyle(.borderless).help("Reminder-Tag und Uhrzeit ändern")
                .popover(isPresented: $showsReminder, arrowEdge: .top) { reminderDetails }
                Text("BCC: \(reminderAddress)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12)).frame(minHeight: 24)
        .onChange(of: state.reminderEnabled) { enabled in if !enabled { showsReminder = false } }
    }

    private var reminderDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Reminder", systemImage: "bell").font(.headline)
            Picker("Tag", selection: $state.reminderDay) {
                ForEach(Self.days, id: \.code) { day in Text(day.label).tag(day.code) }
            }
            .pickerStyle(.segmented).labelsHidden().accessibilityLabel("Reminder-Tag")
            HStack {
                Text("Uhrzeit")
                Spacer()
                Picker("Uhrzeit", selection: $state.reminderTime) {
                    ForEach(Self.times, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 100)
            }
            Text("BCC: \(reminderAddress)").font(.caption.monospaced())
                .foregroundStyle(.secondary).textSelection(.enabled)
            HStack { Spacer(); Button("Fertig") { showsReminder = false } }
        }
        .padding(20).frame(width: 330)
    }

    private var reminderSummary: String {
        let day = Self.days.first { $0.code == state.reminderDay }?.label ?? state.reminderDay
        return "\(day) · \(state.reminderTime)"
    }
    private var reminderAddress: String {
        let time = state.reminderTime.replacingOccurrences(of: ":", with: "")
        return time == "0600" ? "\(state.reminderDay)@fut.io" : "\(state.reminderDay)\(time)@fut.io"
    }

    private var extractionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(state.outputMode == .calendar ? "Termin aus Mail" : "Überweisung aus Mail + PDF",
                  systemImage: state.outputMode == .calendar ? "calendar.badge.plus" : "banknote")
                .font(.title3.weight(.semibold))
            Text(state.outputMode == .calendar
                 ? "Titel, Kurzbeschreibung und erkennbaren Zeitpunkt aus der Mail übernehmen. Den Zielkalender wählst du anschließend aus."
                 : "Empfänger, IBAN, Betrag und Verwendungszweck aus dem PDF-Anhang auslesen. Alle Angaben bleiben vor dem Kopieren bearbeitbar. Es wird keine Überweisung ausgelöst.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading).modifier(WorkspaceCard())
    }
    private var primaryTitle: String {
        switch state.outputMode {
        case .reply: return "Antwort erstellen"
        case .newMail: return "Mail erstellen"
        case .forward: return "Forward erstellen"
        case .calendar: return "Termin erstellen"
        case .payment: return "Überweisung extrahieren"
        }
    }
}

struct MailDraftPreviewView: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(state.outputMode == .newMail ? "Neue Mail" :
                        (state.outputMode == .forward ? "Weiterleitung" : "Antwortvorschlag"))
                    .font(.title3.weight(.semibold))
                if state.outputMode == .newMail {
                    HStack(spacing: 12) {
                        Text("Betreff").font(.caption).foregroundStyle(.secondary)
                        TextField("Betreff", text: $state.newMailSubject).textFieldStyle(.plain)
                    }
                    .padding(12).modifier(WorkspaceCard())
                }
                RichTextMailEditor(plainText: $state.reply, html: $state.replyHTML,
                                   height: nil, showsHTMLBadge: false)
                    .accessibilityLabel("Bearbeitbarer Mailentwurf")
            }
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            WorkspaceActionBar(
                secondaryTitle: "Zurück",
                primaryTitle: state.outputMode == .newMail ? "Neue Mail in Outlook" : "In Outlook einsetzen",
                hint: "Prüfen, einsetzen, selbst senden.",
                secondaryAction: { state.stage = .instruction },
                primaryAction: { state.insertAction?() }
            )
        }
    }
}
