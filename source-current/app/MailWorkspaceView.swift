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
        let isDefault = AppState.ReplyLanguage.allCases.map(\.defaultReplyInstruction).contains(trimmed)
        switch mode {
        case .newMail, .forward:
            if isDefault {
                state.instruction = ""
                state.instructionHTML = ""
            }
            if mode == .newMail { state.newMailSubject = "" }
        case .reply:
            if trimmed.isEmpty {
                state.instruction = state.replyLanguage.defaultReplyInstruction
                state.instructionHTML = ""
            }
        case .calendar, .payment: break
        }
    }

    static func selectReply(all: Bool, in state: AppState) {
        state.replyScope = all ? .all : .sender
        if state.outputMode != .reply {
            select(.reply, in: state)
        } else if state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.instruction = state.replyLanguage.defaultReplyInstruction
            state.instructionHTML = ""
        }
    }
}

struct MailWorkspaceView: View {
    @ObservedObject private var appLocalization = AppLocalization.shared
    @ObservedObject var state: AppState
    @State private var showsReminder = false
    private static var days: [(label: String, code: String)] { [
        (L10n.tr("Mo"), "mon"), (L10n.tr("Di"), "tues"), (L10n.tr("Mi"), "wed"), (L10n.tr("Do"), "thurs"),
        (L10n.tr("Fr"), "fri"), (L10n.tr("Sa"), "sat"), (L10n.tr("So"), "sun")
    ] }
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
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("Deine Anweisung")).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        RichTextMailEditor(plainText: $state.instruction, html: $state.instructionHTML,
                                           height: nil, showsHTMLBadge: false)
                            .accessibilityLabel(L10n.tr("Anweisung für den Mailentwurf"))
                    }
                    .frame(maxHeight: .infinity)
                    optionsRow
                        .fixedSize(horizontal: false, vertical: true)
                    reminderControl
                        .fixedSize(horizontal: false, vertical: true)
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
                secondaryTitle: L10n.tr("Schließen"), primaryTitle: primaryTitle,
                hint: isMail ? L10n.tr("Versendet wird erst in Outlook.") : L10n.tr("Vor dem Übernehmen prüfen."),
                disabled: !MailWorkspaceLogic.canGenerate(state),
                secondaryAction: { state.closeAction?() },
                primaryAction: { state.generateAction?() }
            )
        }
    }

    private var modeRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                if hasMail {
                    replyButton(all: false)
                    replyButton(all: true)
                }
                modeButton(.newMail, symbol: "square.and.pencil")
                if hasMail { modeButton(.forward, symbol: "arrowshape.turn.up.right") }
            }
            .padding(3)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            Spacer(minLength: 4)
            contextLabel
        }
    }

    private func replyButton(all: Bool) -> some View {
        let scope: AppState.ReplyScope = all ? .all : .sender
        let selected = state.outputMode == .reply && state.replyScope == scope
        return Button { MailWorkspaceLogic.selectReply(all: all, in: state) } label: {
            Label(L10n.tr(all ? "Reply All" : "Reply"),
                  systemImage: all ? "arrowshape.turn.up.left.2" : "arrowshape.turn.up.left")
                .lineLimit(1)
        }
        .buttonStyle(WorkspaceChoiceStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                Text(L10n.tr("Lädt …"))
            } else {
                Image(systemName: hasMail ? "checkmark.circle" : "info.circle")
                Text(hasMail ? L10n.tr("Mail erkannt") : L10n.tr("Ohne Mail-Kontext"))
            }
            if !hasMail && state.mailStatus != .loading {
                Button { state.refreshMailAction?() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help(L10n.tr("Outlook-Mail erneut lesen"))
                    .accessibilityLabel(L10n.tr("Outlook-Mail erneut lesen"))
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).help(contextHelp)
    }

    private var contextHelp: String {
        if case .unavailable(let message) = state.mailStatus { return L10n.render(message) }
        return hasMail ? L10n.tr("Die geöffnete Outlook-Mail dient als Kontext.")
            : L10n.tr("Neue Mail ohne Kontext möglich. Für Reply oder Forward zuerst eine Outlook-Mail öffnen.")
    }

    private var optionsRow: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Text(L10n.tr("Ton")).font(.caption).foregroundStyle(.secondary)
                Picker(L10n.tr("Ton"), selection: $state.replyTone) {
                    ForEach(ReplyTone.allCases) { tone in Text(tone.displayName).tag(tone) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 138)
                .accessibilityLabel(L10n.tr("Ton des Mailentwurfs"))
            }
            Toggle(L10n.tr("Compact"), isOn: $state.newMailCompact)
                .toggleStyle(.checkbox).help(L10n.tr("So kurz wie möglich formulieren"))
            Spacer(minLength: 6)
            languageSelector
        }
        .controlSize(.small)
    }

    private var languageSelector: some View {
        HStack(spacing: 2) {
            languageButton("DE", language: .german, title: L10n.tr("Deutsch"))
            languageButton("EN", language: .usEnglish, title: L10n.tr("US English"))
            languageButton("ES", language: .spanish, title: L10n.tr("Español"))
        }
        .padding(3)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain).accessibilityLabel(L10n.tr("Ausgabesprache"))
    }

    private func languageButton(_ label: String, language: AppState.ReplyLanguage, title: String) -> some View {
        Button(label) { state.replyLanguage = language }
            .buttonStyle(WorkspaceChoiceStyle(selected: state.replyLanguage == language))
            .help(title).accessibilityLabel(title)
            .accessibilityAddTraits(state.replyLanguage == language ? .isSelected : [])
    }

    private var reminderControl: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $state.reminderEnabled) { Label(L10n.tr("Reminder"), systemImage: "bell") }
                .toggleStyle(.checkbox).controlSize(.small)
            if state.reminderEnabled {
                Button { showsReminder.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(reminderSummary)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                }
                .buttonStyle(.borderless).help(L10n.tr("Reminder-Tag und Uhrzeit ändern"))
                .popover(isPresented: $showsReminder, arrowEdge: .top) { reminderDetails }
                Text(L10n.tr("BCC: {0}", reminderAddress)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12)).frame(minHeight: 24)
        .onChange(of: state.reminderEnabled) { enabled in if !enabled { showsReminder = false } }
    }

    private var reminderDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.tr("Reminder"), systemImage: "bell").font(.headline)
            Picker(L10n.tr("Tag"), selection: $state.reminderDay) {
                ForEach(Self.days, id: \.code) { day in Text(day.label).tag(day.code) }
            }
            .pickerStyle(.segmented).labelsHidden().accessibilityLabel(L10n.tr("Reminder-Tag"))
            HStack {
                Text(L10n.tr("Uhrzeit"))
                Spacer()
                Picker(L10n.tr("Uhrzeit"), selection: $state.reminderTime) {
                    ForEach(Self.times, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 100)
            }
            Text(L10n.tr("BCC: {0}", reminderAddress)).font(.caption.monospaced())
                .foregroundStyle(.secondary).textSelection(.enabled)
            HStack { Spacer(); Button(L10n.tr("Fertig")) { showsReminder = false } }
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
            Label(state.outputMode == .calendar ? L10n.tr("Termin aus Mail") : L10n.tr("Überweisung aus Mail + PDF"),
                  systemImage: state.outputMode == .calendar ? "calendar.badge.plus" : "banknote")
                .font(.title3.weight(.semibold))
            Text(state.outputMode == .calendar
                 ? L10n.tr("Titel, Kurzbeschreibung und erkennbaren Zeitpunkt aus der Mail übernehmen. Den Zielkalender wählst du anschließend aus.")
                 : L10n.tr("Empfänger, IBAN, Betrag und Verwendungszweck aus dem PDF-Anhang auslesen. Alle Angaben bleiben vor dem Kopieren bearbeitbar. Es wird keine Überweisung ausgelöst."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading).modifier(WorkspaceCard())
    }
    private var primaryTitle: String {
        switch state.outputMode {
        case .reply: return L10n.tr("Antwort erstellen")
        case .newMail: return L10n.tr("Mail erstellen")
        case .forward: return L10n.tr("Forward erstellen")
        case .calendar: return L10n.tr("Termin erstellen")
        case .payment: return L10n.tr("Überweisung extrahieren")
        }
    }
}

struct MailDraftPreviewView: View {
    @ObservedObject private var appLocalization = AppLocalization.shared
    @ObservedObject var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(state.outputMode == .newMail ? L10n.tr("Neue Mail") :
                        (state.outputMode == .forward ? L10n.tr("Weiterleitung") : L10n.tr("Antwortvorschlag")))
                    .font(.title3.weight(.semibold))
                if state.outputMode == .newMail {
                    HStack(spacing: 12) {
                        Text(L10n.tr("Betreff")).font(.caption).foregroundStyle(.secondary)
                        TextField(L10n.tr("Betreff"), text: $state.newMailSubject).textFieldStyle(.plain)
                    }
                    .padding(12).modifier(WorkspaceCard())
                }
                RichTextMailEditor(plainText: $state.reply, html: $state.replyHTML,
                                   height: nil, showsHTMLBadge: false)
                    .accessibilityLabel(L10n.tr("Bearbeitbarer Mailentwurf"))
            }
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            WorkspaceActionBar(
                secondaryTitle: L10n.tr("Zurück"),
                primaryTitle: state.outputMode == .newMail ? L10n.tr("Neue Mail in Outlook") : L10n.tr("In Outlook einsetzen"),
                hint: L10n.tr("Prüfen, einsetzen, selbst senden."),
                secondaryAction: { state.stage = .instruction },
                primaryAction: { state.insertAction?() }
            )
        }
    }
}
