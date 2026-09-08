import AppKit
import SwiftUI

@main
struct WorkspaceUITests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        checkModeLogic()
        try checkZoom()
        let sizes = [NSSize(width: 680, height: 560), NSSize(width: 900, height: 740)]
        let previewDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        var count = 0
        for dark in [false, true] {
            for size in sizes {
                for preview in [false, true] {
                    for mode in [AppState.OutputMode.reply, .newMail, .forward] {
                        let state = AppState()
                        state.stage = preview ? .preview : .instruction
                        state.outputMode = mode
                        state.mailStatus = .available
                        state.instruction = "Bitte freundlich antworten und den vorgeschlagenen Termin bestätigen."
                        state.reply = "Vielen Dank für deine Nachricht. Der vorgeschlagene Termin passt gut."
                        state.newMailSubject = "Unser Termin"
                        state.reminderEnabled = true
                        let host = NSHostingView(rootView: OverlayView(state: state))
                        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        window.contentView = host
                        window.setContentSize(size)
                        window.orderFrontRegardless()
                        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                        host.layoutSubtreeIfNeeded()
                        let editors = descendants(host).compactMap { $0 as? NSScrollView }
                            .filter { $0.identifier?.rawValue == "replyzen.mailEditor" }
                        precondition(editors.count == 1, "Expected one native mail editor")
                        let editor = editors[0]
                        let rect = editor.convert(editor.bounds, to: host)
                        precondition(rect.width > 250 && rect.height >= 75, "Editor collapsed: \(rect)")
                        precondition(rect.minX >= -1 && rect.maxX <= host.bounds.maxX + 1, "Horizontal clipping")
                        precondition(rect.minY >= -1 && rect.maxY <= host.bounds.maxY + 1, "Vertical clipping")
                        precondition(abs(editor.magnification - 1.30) < 0.001, "Lost default visual zoom")
                        let textView = editor.documentView as! NSTextView
                        precondition(textView.string == (preview ? state.reply : state.instruction))
                        let font = textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
                        precondition(abs(font.pointSize - 10.5) < 0.001)
                        if mode == .reply && !preview {
                            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                                fatalError("Unable to render native workspace")
                            }
                            host.cacheDisplay(in: host.bounds, to: bitmap)
                            let png = bitmap.representation(using: .png, properties: [:])!
                            let name = "workspace-\(dark ? "dark" : "light")-\(Int(size.width)).png"
                            try png.write(to: previewDirectory.appendingPathComponent(name))
                        }
                        window.orderOut(nil)
                        window.close()
                        count += 1
                    }
                }
            }
        }
        print("PASS: \(count) native editor layouts, light/dark, minimum/default sizes, reply/new/forward and preview")
        print("Synthetic test content only; no Outlook or API access.")
    }

    @MainActor private static func checkModeLogic() {
        let state = AppState()
        precondition(!MailWorkspaceLogic.canGenerate(state))
        state.outputMode = .newMail
        state.instruction = "Write an email"
        precondition(MailWorkspaceLogic.canGenerate(state))
        state.outputMode = .reply
        precondition(!MailWorkspaceLogic.canGenerate(state))
        state.mailStatus = .available
        precondition(MailWorkspaceLogic.canGenerate(state))
        state.instructionHTML = "<b>Write an email</b>"
        state.reminderEnabled = true
        MailWorkspaceLogic.select(.forward, in: state)
        precondition(state.instruction == "Write an email" && state.instructionHTML == "<b>Write an email</b>")
        precondition(state.reminderEnabled)
        state.instruction = "Kurz, freundlich und direkt antworten."
        MailWorkspaceLogic.select(.newMail, in: state)
        precondition(state.instruction.isEmpty && state.instructionHTML.isEmpty)
        precondition(!MailWorkspaceLogic.canGenerate(state))
        state.replyLanguage = .usEnglish
        MailWorkspaceLogic.select(.reply, in: state)
        precondition(state.instruction == "Reply briefly, friendly and directly.")
        state.outputMode = .calendar
        state.instruction = ""
        precondition(MailWorkspaceLogic.canGenerate(state))
        state.mailStatus = .unavailable("Test only")
        precondition(!MailWorkspaceLogic.canGenerate(state))
        print("PASS: generation guards and non-destructive mode transitions")
    }

    @MainActor private static func checkZoom() throws {
        let controller = RichTextEditorController()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 220))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 220))
        text.textStorage?.setAttributedString(NSAttributedString(string: "Test", attributes: [.font: MailTypography.baseFont]))
        scroll.documentView = text
        scroll.allowsMagnification = true
        scroll.minMagnification = 1.0
        scroll.maxMagnification = 1.8
        scroll.magnification = 1.3
        controller.textView = text
        controller.attachZoom(to: scroll)
        for percent in [100, 115, 130, 150, 180, 220, 50] {
            controller.setZoom(percent: percent)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let expected = min(180, max(100, percent))
            precondition(controller.zoomPercent == expected)
            let font = text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
            precondition(abs(font.pointSize - 10.5) < 0.001 && text.string == "Test")
        }
        scroll.magnification = 1.47
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(controller.zoomPercent == 147)
        print("PASS: zoom selection, range clamps and gesture observation preserve 10.5 pt text")
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}
