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
            Spacer(minLength: 0)
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
