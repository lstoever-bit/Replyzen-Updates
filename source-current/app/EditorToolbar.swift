import SwiftUI

struct EditorToolbar: View {
    @ObservedObject private var appLocalization = AppLocalization.shared
    @ObservedObject var adapter: ReplyZenRichEditorAdapter

    var body: some View {
        HStack(spacing: 4) {
            tool("bold", title: L10n.tr("Fett"), action: adapter.toggleBold)
            tool("italic", title: L10n.tr("Kursiv"), action: adapter.toggleItalic)
            separator
            tool("list.bullet", title: L10n.tr("Aufzählung"), action: adapter.toggleBullets)
            tool("list.number", title: L10n.tr("Nummerierte Liste"), action: adapter.toggleNumbering)
            separator
            tool("textformat", title: L10n.tr("Formatierung entfernen"), action: adapter.clearFormatting)
            Spacer(minLength: 8)
            Menu {
                ForEach([100, 115, 130, 150, 180], id: \.self) { percent in
                    Button {
                        adapter.setZoom(percent: percent)
                    } label: {
                        if adapter.zoomPercent == percent {
                            Label("\(percent) %", systemImage: "checkmark")
                        } else {
                            Text("\(percent) %")
                        }
                    }
                }
                Divider()
                Text(L10n.tr("Nur Anzeige, kein Einfluss auf Outlook"))
            } label: {
                Text("\(adapter.zoomPercent) %")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L10n.tr("Editor-Zoom. Outlook erhält unverändert Calibri Light 10,5 pt."))
            .accessibilityLabel(L10n.tr("Editor-Zoom"))
            .accessibilityValue(L10n.tr("{0} Prozent", adapter.zoomPercent))
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var separator: some View { Divider().frame(height: 16).padding(.horizontal, 4) }
    private func tool(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.borderless).help(title).accessibilityLabel(title)
    }
}
