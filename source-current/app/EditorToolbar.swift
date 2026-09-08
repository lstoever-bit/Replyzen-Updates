import SwiftUI

struct EditorToolbar: View {
    @ObservedObject var controller: RichTextEditorController
    var body: some View {
        HStack(spacing: 4) {
            tool("bold", title: "Fett", action: controller.toggleBold)
            tool("italic", title: "Kursiv", action: controller.toggleItalic)
            separator
            tool("list.bullet", title: "Aufzählung", action: controller.toggleBullets)
            tool("list.number", title: "Nummerierte Liste", action: controller.toggleNumbering)
            separator
            tool("textformat", title: "Formatierung entfernen", action: controller.clearFormatting)
            Spacer(minLength: 8)
            Menu {
                ForEach([100, 115, 130, 150, 180], id: \.self) { percent in
                    Button {
                        controller.setZoom(percent: percent)
                    } label: {
                        if controller.zoomPercent == percent {
                            Label("\(percent) %", systemImage: "checkmark")
                        } else {
                            Text("\(percent) %")
                        }
                    }
                }
                Divider()
                Text("Nur Anzeige, kein Einfluss auf Outlook")
            } label: {
                Text("\(controller.zoomPercent) %")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Editor-Zoom. Outlook erhält unverändert Calibri Light 10,5 pt.")
            .accessibilityLabel("Editor-Zoom")
            .accessibilityValue("\(controller.zoomPercent) Prozent")
        }
        .padding(.horizontal, 10).frame(height: 36)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
    private var separator: some View {
        Divider().frame(height: 16).padding(.horizontal, 4)
    }
    private func tool(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.borderless).help(title).accessibilityLabel(title)
    }
}
