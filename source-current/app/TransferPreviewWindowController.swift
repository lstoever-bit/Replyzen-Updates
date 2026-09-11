import AppKit

final class TransferPreviewWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var completion: ((Bool) -> Void)?

    func show(payload: ChatGPTTransferPayload, completion: @escaping (Bool) -> Void) {
        finish(false, invokeCompletion: false)
        self.completion = completion

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("Übergabe an ChatGPT prüfen")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 420)
        window.delegate = self

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let title = NSTextField(labelWithString: L10n.tr("Diese Daten werden an ChatGPT übergeben"))
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let info = NSTextField(wrappingLabelWithString: L10n.tr("Prüfe den Inhalt. Erst nach deiner Bestätigung wird genau dieser Datenblock gesendet."))
        info.textColor = .secondaryLabelColor
        info.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = payload.apiJSON
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.horizontalScrollElasticity = .none

        let cancel = NSButton(title: L10n.tr("Abbrechen"), target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        let confirm = NSButton(title: L10n.tr("An ChatGPT senden"), target: self, action: #selector(confirmPressed))
        confirm.keyEquivalent = "\r"
        confirm.bezelStyle = .rounded

        let buttons = NSStackView(views: [cancel, confirm])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY
        buttons.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(info)
        root.addSubview(scroll)
        root.addSubview(buttons)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            info.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            info.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            info.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: info.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),

            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func confirmPressed() {
        finish(true)
    }

    @objc private func cancelPressed() {
        finish(false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(false)
        return false
    }

    private func finish(_ accepted: Bool, invokeCompletion: Bool = true) {
        let callback = completion
        completion = nil
        window?.delegate = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        if invokeCompletion { callback?(accepted) }
    }
}
