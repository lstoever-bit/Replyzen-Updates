import AppKit
import SwiftUI

/// Shared semantic surfaces adapt to macOS light/dark appearance.
struct WorkspaceCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5))
    }
}

struct WorkspaceChoiceStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.65 : 1)
            .contentShape(Rectangle())
    }
}

struct WorkspaceHeader: View {
    @ObservedObject var state: AppState
    @State private var showsOptions = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = ReplyZenBrand.logo {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "envelope.badge").resizable().scaledToFit().padding(8)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(ReplyZenBrand.displayName)
                    .font(.system(size: 21, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Mail AI")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text(statusTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            Button { showsOptions.toggle() } label: {
                Image(systemName: "gearshape").frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("Einstellungen und Hinweise")
            .accessibilityLabel("Einstellungen und Hinweise")
            .popover(isPresented: $showsOptions, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(ReplyZenBrand.displayName).font(.headline)
                    Text("Öffnen in Outlook: ⌃⌥R")
                    Text("Der Editor-Zoom verändert nur die Anzeige. Mailtext wird weiterhin in Calibri Light, 10,5 pt eingesetzt.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Button("API-Key ändern …") {
                        showsOptions = false
                        state.stage = .apiKey
                    }
                    Button("Bedienungshilfen öffnen …") {
                        showsOptions = false
                        state.openAccessibilityAction?()
                    }
                    Text("Updates und weitere Optionen findest du im ReplyZen-Menü in der macOS-Menüleiste.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20).frame(width: 300)
            }
        }
        // Reserve space for native window controls in full-size content.
        .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 14)
        .accessibilityElement(children: .contain)
    }

    private var statusTitle: String {
        switch state.stage {
        case .preview: return "Entwurf prüfen"
        case .calendarPreview: return "Termin prüfen"
        case .paymentPreview: return "Daten prüfen"
        default: return "Bereit"
        }
    }
}

/// Kept outside scrolling content so primary actions remain visible.
struct WorkspaceActionBar: View {
    let secondaryTitle: String
    let primaryTitle: String
    var hint: String = ""
    var disabled = false
    let secondaryAction: () -> Void
    let primaryAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button(secondaryTitle, action: secondaryAction)
                    .keyboardShortcut(.cancelAction)
                Text(hint).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(disabled)
            }
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("replyzen.actionBar")
    }
}
