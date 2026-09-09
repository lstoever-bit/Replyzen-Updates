#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(sys.argv[1])
app = root / "app"

# 1) Restore the WYSIWYG editor zoom on the new stable native AppKit wrapper.
path = app / "RichTextMailEditor.swift"
text = path.read_text(encoding="utf-8")
if "private weak var scrollView: NSScrollView?" not in text:
    text = text.replace(
        "    weak var textView: RichTextView?\n",
        "    weak var textView: RichTextView?\n"
        "    private weak var scrollView: NSScrollView?\n"
        "    private var zoomObservation: NSKeyValueObservation?\n"
        "    @Published private(set) var zoomPercent: Int = {\n"
        "        let saved = UserDefaults.standard.integer(forKey: \"ReplyZen.EditorZoomPercent\")\n"
        "        return [100, 115, 130, 150, 180].contains(saved) ? saved : 130\n"
        "    }()\n"
    )

if "func attachZoom(to scrollView: NSScrollView)" not in text:
    marker = "    func attach(_ view: RichTextView) {\n"
    idx = text.index(marker)
    zoom_code = '''    func attachZoom(to scrollView: NSScrollView) {
        if self.scrollView === scrollView { return }
        self.scrollView = scrollView
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1.0
        scrollView.maxMagnification = 1.8
        scrollView.magnification = CGFloat(zoomPercent) / 100.0
        zoomObservation = scrollView.observe(\\.magnification, options: [.new]) { [weak self, weak scrollView] _, _ in
            DispatchQueue.main.async {
                guard let self, let scrollView, self.scrollView === scrollView else { return }
                let percent = Int((scrollView.magnification * 100).rounded())
                if percent != self.zoomPercent { self.zoomPercent = percent }
            }
        }
    }

    func setZoom(percent: Int) {
        guard let scrollView else { return }
        let clamped = min(180, max(100, percent))
        scrollView.magnification = CGFloat(clamped) / 100.0
        zoomPercent = clamped
        UserDefaults.standard.set(clamped, forKey: "ReplyZen.EditorZoomPercent")
    }

'''
    text = text[:idx] + zoom_code + text[idx:]

if "adapter.attachZoom(to: scroll)" not in text:
    text = text.replace(
        "        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)\n"
        "        if let view = scroll.documentView as? RichTextView { adapter.attach(view) }\n",
        "        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)\n"
        "        adapter.attachZoom(to: scroll)\n"
        "        if let view = scroll.documentView as? RichTextView { adapter.attach(view) }\n"
    )
    text = text.replace(
        "    func updateNSView(_ scroll: NSScrollView, context: Context) {\n"
        "        if let view = scroll.documentView as? RichTextView { adapter.attach(view) }\n"
        "    }\n",
        "    func updateNSView(_ scroll: NSScrollView, context: Context) {\n"
        "        adapter.attachZoom(to: scroll)\n"
        "        if let view = scroll.documentView as? RichTextView { adapter.attach(view) }\n"
        "    }\n"
    )
path.write_text(text, encoding="utf-8")

# 2) Put the visible zoom menu back into the editor toolbar.
path = app / "EditorToolbar.swift"
text = path.read_text(encoding="utf-8")
if "Editor-Zoom" not in text:
    text = text.replace(
        "            Spacer(minLength: 0)\n",
        '''            Spacer(minLength: 8)
            Menu {
                ForEach([100, 115, 130, 150, 180], id: \\.self) { percent in
                    Button {
                        adapter.setZoom(percent: percent)
                    } label: {
                        if adapter.zoomPercent == percent {
                            Label("\\(percent) %", systemImage: "checkmark")
                        } else {
                            Text("\\(percent) %")
                        }
                    }
                }
                Divider()
                Text(L10n.tr("Nur Anzeige, kein Einfluss auf Outlook"))
            } label: {
                Text("\\(adapter.zoomPercent) %")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L10n.tr("Editor-Zoom. Outlook erhält unverändert Calibri Light, 10,5 pt."))
            .accessibilityLabel(L10n.tr("Editor-Zoom"))
            .accessibilityValue(L10n.tr("{0} Prozent", adapter.zoomPercent))
'''
    )
path.write_text(text, encoding="utf-8")

# 3) Add Cmd+A so the subject is entered as real keyboard editing, not only an AX value.
path = app / "KeyboardController.swift"
text = path.read_text(encoding="utf-8")
if "func sendCommandA()" not in text:
    text = text.replace(
        "    func sendCommandV() {\n        sendKey(code: 9, flags: .maskCommand)\n    }\n",
        "    func sendCommandA() {\n        sendKey(code: 0, flags: .maskCommand)\n    }\n\n"
        "    func sendCommandV() {\n        sendKey(code: 9, flags: .maskCommand)\n    }\n"
    )
path.write_text(text, encoding="utf-8")

# 4) New-mail subject: do not use AXValue as the final edit. Outlook can display that
# value while its native compose model still considers the subject empty. Focus the
# real subject field, select all, paste with Cmd+V, then Tab out so Outlook commits it.
path = app / "AppDelegate.swift"
text = path.read_text(encoding="utf-8")
start = text.index("    private func populateNewMailDraft(subject: String, body: String, html: String, attempt: Int) {")
end = text.index("    private func finishNewMailInsertion()", start)
new_func = '''    private func populateNewMailDraft(subject: String, body: String, html: String, attempt: Int) {
        let delay = attempt == 0 ? 0.8 : 0.24
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }

            if let reminder = self.reminderBCCAddress() {
                _ = self.outlook.setComposeBCCValue(reminder)
            }

            if !subject.isEmpty {
                guard self.outlook.focusComposeSubjectField() else {
                    if attempt < 8 {
                        self.populateNewMailDraft(subject: subject, body: body, html: html, attempt: attempt + 1)
                    } else {
                        self.copyMailToPasteboard(plainText: body, html: html)
                        self.isRunningFlow = false
                        self.showError(L10n.source("Der Betreff konnte nicht zuverlässig in Outlook eingesetzt werden. Der Mailtext liegt in der Zwischenablage."))
                    }
                    return
                }

                // AXValue alone can paint the subject text without committing it to
                // Outlook's native compose model. Real keyboard editing + leaving
                // the field makes Outlook register the subject before Send is used.
                self.copyToPasteboard(subject)
                self.keyboard.sendCommandA()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self else { return }
                    self.keyboard.sendCommandV()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
                        guard let self else { return }
                        self.keyboard.sendTab()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                            guard let self else { return }
                            self.copyMailToPasteboard(plainText: body, html: html)
                            self.keyboard.sendCommandV()
                            self.finishNewMailInsertion()
                        }
                    }
                }
                return
            }

            if self.outlook.focusComposeBodyField() {
                self.copyMailToPasteboard(plainText: body, html: html)
                self.keyboard.sendCommandV()
                self.finishNewMailInsertion()
                return
            }

            // Classic Outlook can hide the body from Accessibility. Subject is the
            // stable landmark; one Tab from it moves into the native message body.
            if self.outlook.focusComposeSubjectField() {
                self.keyboard.sendTab()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                    guard let self else { return }
                    self.copyMailToPasteboard(plainText: body, html: html)
                    self.keyboard.sendCommandV()
                    self.finishNewMailInsertion()
                }
                return
            }

            if attempt < 8 {
                self.populateNewMailDraft(subject: subject, body: body, html: html, attempt: attempt + 1)
                return
            }

            self.copyMailToPasteboard(plainText: body, html: html)
            self.isRunningFlow = false
            self.showError(L10n.source("Der Mailtext konnte nicht automatisch eingesetzt werden. Er liegt in der Zwischenablage."))
        }
    }

'''
text = text[:start] + new_func + text[end:]
path.write_text(text, encoding="utf-8")

# 5) Version and release notes.
path = app / "Info.plist"
text = path.read_text(encoding="utf-8")
text = text.replace("<string>1.55.0</string>", "<string>1.56.0</string>")
text = text.replace("<string>56</string>", "<string>57</string>")
path.write_text(text, encoding="utf-8")

notes_de = (
    "ReplyZen 1.56: Der sichtbare Editor-Zoom ist zurück (100/115/130/150/180 %) und bleibt über Sitzungen hinweg erhalten; "
    "er verändert weiterhin nur die Anzeige, nicht die Outlook-Schrift. Neue Mail-Betreffzeilen werden nicht mehr nur per Accessibility gesetzt, "
    "sondern wie eine echte Eingabe fokussiert, markiert, eingefügt und mit Tab bestätigt. Dadurch erkennt Outlook den sichtbaren Betreff auch intern "
    "und sollte die Warnung 'ohne Betreff senden' nicht mehr fälschlich anzeigen. Der Fenster-Fix aus 1.55 bleibt unverändert erhalten."
)
notes_en = (
    "ReplyZen 1.56: The visible editor zoom is back (100/115/130/150/180%) and is remembered across sessions; it still changes display only, "
    "not the font sent to Outlook. New-mail subjects are no longer only assigned through Accessibility. ReplyZen now focuses the real Subject field, "
    "selects its contents, pastes the subject with native keyboard input, and tabs out to commit it. This makes Outlook register the visible subject "
    "internally as well and should prevent the false 'send without subject' warning. The 1.55 window fix remains unchanged."
)
notes_es = (
    "ReplyZen 1.56: Vuelve el zoom visible del editor (100/115/130/150/180 %) y se conserva entre sesiones; solo cambia la visualización y no la fuente "
    "que recibe Outlook. Los asuntos de correos nuevos ya no se asignan únicamente mediante Accesibilidad. ReplyZen enfoca el campo Asunto real, "
    "selecciona su contenido, pega el asunto con entrada de teclado nativa y sale con Tab para confirmarlo. Así Outlook registra también internamente "
    "el asunto visible y debería evitar el aviso erróneo de envío sin asunto. El arreglo de ventana de 1.55 se mantiene sin cambios."
)
(root / "Release-notes.txt").write_text(notes_de + "\n", encoding="utf-8")

import json
(root / "Release-notes.localized.json").write_text(
    json.dumps({"de": notes_de, "en-US": notes_en, "es": notes_es}, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8"
)

# 6) Update source contracts so CI protects both regressions.
path = Path("tests/test_source_contracts.py")
text = path.read_text(encoding="utf-8")
text = text.replace('self.assertEqual(info["CFBundleShortVersionString"], "1.55.0")',
                    'self.assertEqual(info["CFBundleShortVersionString"], "1.56.0")')
text = text.replace('self.assertEqual(info["CFBundleVersion"], "56")',
                    'self.assertEqual(info["CFBundleVersion"], "57")')
if 'self.assertIn("scrollView.allowsMagnification = true", editor)' not in text:
    text = text.replace(
        '        self.assertIn("MailTypography.normalizeFonts", editor)\n',
        '        self.assertIn("MailTypography.normalizeFonts", editor)\n'
        '        self.assertIn("scrollView.allowsMagnification = true", editor)\n'
        '        self.assertIn("adapter.attachZoom(to: scroll)", editor)\n'
        '        self.assertIn("adapter.zoomPercent", toolbar)\n'
        '        self.assertIn("Editor-Zoom", toolbar)\n'
    )
if "test_new_mail_subject_uses_native_keyboard_commit" not in text:
    insert_at = text.index("    def test_window_position_contract(self):")
    test_code = '''    def test_new_mail_subject_uses_native_keyboard_commit(self):
        delegate = self.read("AppDelegate.swift")
        keyboard = self.read("KeyboardController.swift")
        self.assertIn("func sendCommandA()", keyboard)
        self.assertIn("self.keyboard.sendCommandA()", delegate)
        self.assertIn("self.keyboard.sendCommandV()", delegate)
        self.assertIn("self.keyboard.sendTab()", delegate)
        self.assertNotIn("setComposeSubjectValue(subject)", delegate)

'''
    text = text[:insert_at] + test_code + text[insert_at:]
path.write_text(text, encoding="utf-8")

print("Migrated ReplyZen to 1.56.0 / build 57: editor zoom restored, Outlook subject committed natively")
