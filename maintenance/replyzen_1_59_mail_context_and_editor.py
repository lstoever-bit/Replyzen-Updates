#!/usr/bin/env python3
"""ReplyZen 1.59: faster mail context, safe editor selection, reliable user instructions."""
from pathlib import Path
import json
import plistlib
import sys

root = Path(sys.argv[1])
repo = root.parent
app = root / "app"
info_path = app / "Info.plist"
info = plistlib.loads(info_path.read_bytes())


def replace_once(text: str, before: str, after: str, label: str) -> str:
    count = text.count(before)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one marker, found {count}")
    return text.replace(before, after, 1)


if info.get("CFBundleShortVersionString") == "1.59.0":
    outlook = (app / "OutlookAccessibility.swift").read_text(encoding="utf-8")
    panel = (app / "FloatingPanelController.swift").read_text(encoding="utf-8")
    editor = (app / "RichTextMailEditor.swift").read_text(encoding="utf-8")
    workspace = (app / "MailWorkspaceView.swift").read_text(encoding="utf-8")
    delegate = (app / "AppDelegate.swift").read_text(encoding="utf-8")
    client = (app / "OpenAIClient.swift").read_text(encoding="utf-8")
    assert "fastMailText(in window:" in outlook
    assert "selectInstructionTextSoon(expectedText:" in panel
    assert "replyZenCommitRichEditors" in editor and "flushPendingEdits" in editor
    assert workspace.count("replyZenCommitRichEditors") >= 2
    refresh = delegate[delegate.index("private func refreshMailContext()") : delegate.index("private func generateCurrentOutput()")]
    assert "selectInstructionTextSoon" not in refresh
    assert "instructionAtLoadStart" in refresh
    assert "USER INSTRUCTION is authoritative" in client
    print("ReplyZen 1.59 mail/editor migration already applied")
    raise SystemExit(0)

if info.get("CFBundleShortVersionString") != "1.58.0" or str(info.get("CFBundleVersion")) != "59":
    raise SystemExit("Unexpected ReplyZen source version; refusing to modify")

# 1) Fast path for the common Outlook reading-pane/message-window case.
outlook_path = app / "OutlookAccessibility.swift"
outlook = outlook_path.read_text(encoding="utf-8")
old_read = '''    func readMail(from snapshot: Snapshot) throws -> String {
        var best = ""

        for window in snapshot.windows {
            let webAreas = findElements(role: "AXWebArea", root: window, maxNodes: 18_000)
            for webArea in webAreas {
                let text = collectStaticText(root: webArea, maxNodes: 18_000)
                if text.count > best.count {
                    best = text
                }
            }
        }

        let cleaned = cleanup(best)
        guard cleaned.count > 20 else { throw OutlookError.noMailText }
        return cleaned
    }
'''
new_read = '''    func readMail(from snapshot: Snapshot) throws -> String {
        // Most Outlook windows expose the active message web area near the top of
        // the accessibility tree. Resolve that small area first so ReplyZen does
        // not walk tens of thousands of AX nodes for every normal reply.
        for window in snapshot.windows {
            if let fast = fastMailText(in: window) { return fast }
        }

        // Keep the previous deep scan as a compatibility fallback for unusual
        // Outlook layouts. Correctness wins when the fast path cannot identify a
        // readable message.
        var best = ""
        for window in snapshot.windows {
            let webAreas = findElements(role: "AXWebArea", root: window, maxNodes: 18_000)
            for webArea in webAreas {
                let text = collectStaticText(root: webArea, maxNodes: 18_000)
                if text.count > best.count { best = text }
            }
        }

        let cleaned = cleanup(best)
        guard cleaned.count > 20 else { throw OutlookError.noMailText }
        return cleaned
    }

    private func fastMailText(in window: AXUIElement) -> String? {
        let webAreas = findElements(role: "AXWebArea", root: window, maxNodes: 4_500)
        guard !webAreas.isEmpty else { return nil }

        // The message body is normally the largest visible web area. Inspect only
        // the three strongest candidates before falling back to the legacy scan.
        let ranked = webAreas.sorted { left, right in
            let leftSize = sizeAttribute(kAXSizeAttribute as CFString, from: left) ?? .zero
            let rightSize = sizeAttribute(kAXSizeAttribute as CFString, from: right) ?? .zero
            return leftSize.width * leftSize.height > rightSize.width * rightSize.height
        }

        var best = ""
        for webArea in ranked.prefix(3) {
            let cleaned = cleanup(collectStaticText(root: webArea, maxNodes: 6_000))
            if cleaned.count > best.count { best = cleaned }
        }
        return best.count > 20 ? best : nil
    }
'''
outlook = replace_once(outlook, old_read, new_read, "Outlook readMail")
outlook_path.write_text(outlook, encoding="utf-8")

# 2) Selection attempts must be tied to the original default text. Once the user
# types, later delayed selection attempts are cancelled by the equality guard.
panel_path = app / "FloatingPanelController.swift"
panel = panel_path.read_text(encoding="utf-8")
old_select = '''    func selectInstructionTextSoon() {
        let delays: [TimeInterval] = [0.05, 0.16, 0.34]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.selectInstructionTextIfPossible()
            }
        }
    }

    private func selectInstructionTextIfPossible() {
        guard panel.isVisible, state.stage == .instruction, state.outputMode == .reply,
              let root = panel.contentView else { return }
        let expected = state.instruction
        guard !expected.isEmpty else { return }
        if let textView = findInstructionTextView(in: root, expectedText: expected) {
            panel.makeKey()
            panel.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }
'''
new_select = '''    func selectInstructionTextSoon(expectedText: String? = nil) {
        let expected = expectedText ?? state.instruction
        guard !expected.isEmpty else { return }
        let delays: [TimeInterval] = [0.05, 0.16, 0.34]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.selectInstructionTextIfPossible(expectedText: expected)
            }
        }
    }

    private func selectInstructionTextIfPossible(expectedText: String) {
        guard panel.isVisible, state.stage == .instruction, state.outputMode == .reply,
              state.instruction == expectedText,
              let root = panel.contentView else { return }
        if let textView = findInstructionTextView(in: root, expectedText: expectedText) {
            panel.makeKey()
            panel.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }
'''
panel = replace_once(panel, old_select, new_select, "safe instruction selection")
panel_path.write_text(panel, encoding="utf-8")

# 3) Synchronize rich editor content without the artificial 20 ms debounce and
# expose an explicit flush signal before Generate/Insert actions.
editor_path = app / "RichTextMailEditor.swift"
editor = editor_path.read_text(encoding="utf-8")
if "static let replyZenCommitRichEditors" not in editor:
    editor = editor.replace(
        "import RichEditorSwiftUI\n\n",
        "import RichEditorSwiftUI\n\nextension Notification.Name {\n"
        "    static let replyZenCommitRichEditors = Notification.Name(\"ReplyZen.CommitRichEditors\")\n"
        "}\n\n",
        1,
    )
old_schedule = '''    private func schedulePublish() {
        guard !isApplyingExternalValue else { return }
        publishWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.publishCurrentValue() }
        publishWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: item)
    }
'''
new_schedule = '''    private func schedulePublish() {
        guard !isApplyingExternalValue else { return }
        publishWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.publishCurrentValue() }
        publishWorkItem = item
        // Queue on the current run loop with no artificial debounce. This keeps the
        // SwiftUI binding current before a following mouse click can generate mail.
        DispatchQueue.main.async(execute: item)
    }

    func flushPendingEdits() {
        publishWorkItem?.cancel()
        publishWorkItem = nil
        publishCurrentValue()
    }
'''
editor = replace_once(editor, old_schedule, new_schedule, "rich editor publishing")
old_onchange = '''        .onChange(of: plainText) { newValue in adapter.updateExternal(plainText: newValue, html: html) }
        .onChange(of: html) { newValue in adapter.updateExternal(plainText: plainText, html: newValue) }
'''
new_onchange = '''        .onChange(of: plainText) { newValue in adapter.updateExternal(plainText: newValue, html: html) }
        .onChange(of: html) { newValue in adapter.updateExternal(plainText: plainText, html: newValue) }
        .onReceive(NotificationCenter.default.publisher(for: .replyZenCommitRichEditors)) { _ in
            adapter.flushPendingEdits()
        }
'''
editor = replace_once(editor, old_onchange, new_onchange, "rich editor flush observer")
editor_path.write_text(editor, encoding="utf-8")

# 4) Flush visible WYSIWYG state before Generate and before inserting an edited
# preview. The actual action runs on the next main-loop turn after the flush.
workspace_path = app / "MailWorkspaceView.swift"
workspace = workspace_path.read_text(encoding="utf-8")
old_generate = '                primaryAction: { state.generateAction?() }\n'
new_generate = '''                primaryAction: {
                    NotificationCenter.default.post(name: .replyZenCommitRichEditors, object: nil)
                    DispatchQueue.main.async { state.generateAction?() }
                }
'''
workspace = replace_once(workspace, old_generate, new_generate, "workspace generate flush")
old_insert = '                primaryAction: { state.insertAction?() }\n'
new_insert = '''                primaryAction: {
                    NotificationCenter.default.post(name: .replyZenCommitRichEditors, object: nil)
                    DispatchQueue.main.async { state.insertAction?() }
                }
'''
workspace = replace_once(workspace, old_insert, new_insert, "preview insert flush")
workspace_path.write_text(workspace, encoding="utf-8")

# 5) Move default-text selection to the initial opening only. Mail recognition may
# update language/default text, but must never select or replace text typed while it
# was loading.
delegate_path = app / "AppDelegate.swift"
delegate = delegate_path.read_text(encoding="utf-8")
old_open_tail = '''        toolbarButton.setSuppressed(true)
        state.stage = .instruction
        panel.show(activate: true)

        refreshMailContext()
    }
'''
new_open_tail = '''        toolbarButton.setSuppressed(true)
        state.stage = .instruction
        panel.show(activate: true)

        if state.outputMode == .reply {
            panel.selectInstructionTextSoon(expectedText: state.instruction)
        }
        refreshMailContext()
    }
'''
delegate = replace_once(delegate, old_open_tail, new_open_tail, "initial reply selection")
old_load_start = '''        isLoadingMail = true
        state.mailStatus = .loading

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
'''
new_load_start = '''        isLoadingMail = true
        state.mailStatus = .loading
        let instructionAtLoadStart = state.instruction

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
'''
delegate = replace_once(delegate, old_load_start, new_load_start, "capture instruction before load")
old_reply_completion = '''                    if self.state.outputMode == .reply {
                        if self.state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                           self.isDefaultReplyInstruction(self.state.instruction) {
                            self.state.instruction = self.defaultReplyInstruction(for: self.state.replyLanguage)
                            self.state.instructionHTML = ""
                        }
                        // The lightweight suggestion is selected so typing replaces
                        // it immediately.
                        self.panel.selectInstructionTextSoon()
                    }
'''
new_reply_completion = '''                    if self.state.outputMode == .reply {
                        let initialWasDefault = instructionAtLoadStart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            self.isDefaultReplyInstruction(instructionAtLoadStart)
                        let userHasNotEdited = self.state.instruction == instructionAtLoadStart
                        if initialWasDefault && userHasNotEdited {
                            self.state.instruction = self.defaultReplyInstruction(for: self.state.replyLanguage)
                            self.state.instructionHTML = ""
                        }
                        // Never select text when asynchronous mail loading finishes.
                        // The user may already be typing in the instruction editor.
                    }
'''
delegate = replace_once(delegate, old_reply_completion, new_reply_completion, "preserve typed instruction after load")
delegate_path.write_text(delegate, encoding="utf-8")

# 6) Make prompt priority explicit in addition to fixing the UI binding race.
client_path = app / "OpenAIClient.swift"
client = client_path.read_text(encoding="utf-8")
needle = '            "Follow the user\'s instruction precisely. The language of the instruction is input only and must never override the selected output language.",\n'
replacement = needle + '            "The USER INSTRUCTION is authoritative. Reflect every explicit requested point in the reply unless it conflicts with the source email or would require inventing facts. Do not silently omit user-provided instructions.",\n'
client = replace_once(client, needle, replacement, "reply prompt priority")
client_path.write_text(client, encoding="utf-8")

# 7) Version and localized release notes.
info["CFBundleShortVersionString"] = "1.59.0"
info["CFBundleVersion"] = "60"
info_path.write_bytes(plistlib.dumps(info, sort_keys=False))

notes = {
    "de": "ReplyZen 1.59: Die Outlook-Mailerkennung hat jetzt einen schnellen Lesepfad und fällt nur bei ungewöhnlichen Outlook-Layouts auf die bisherige Tiefensuche zurück. Wenn du während des Ladens bereits schreibst, wird dein Text nach Abschluss der Erkennung nicht mehr erneut markiert oder durch einen Sprach-/Standardtext ersetzt. WYSIWYG-Eingaben werden unmittelbar synchronisiert und vor Antwort erstellen bzw. Einsetzen zusätzlich explizit übernommen, damit deine Anweisung zuverlässig im Entwurf berücksichtigt wird.",
    "en-US": "ReplyZen 1.59: Outlook mail detection now uses a fast reading path and falls back to the previous deep scan only for unusual Outlook layouts. If you start typing while mail context is still loading, ReplyZen no longer reselects or replaces your text when detection completes. WYSIWYG edits are synchronized immediately and explicitly flushed before Generate or Insert so your instruction is reliably included in the draft.",
    "es": "ReplyZen 1.59: La detección de correo de Outlook utiliza ahora una ruta de lectura rápida y solo recurre al análisis profundo anterior en diseños poco habituales de Outlook. Si empiezas a escribir mientras se carga el contexto, ReplyZen ya no vuelve a seleccionar ni reemplaza tu texto al terminar la detección. Las ediciones WYSIWYG se sincronizan de inmediato y se confirman explícitamente antes de Generar o Insertar para que tu instrucción se incluya de forma fiable en el borrador."
}
(root / "Release-notes.txt").write_text(notes["de"] + "\n", encoding="utf-8")
(root / "Release-notes.localized.json").write_text(json.dumps(notes, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

# 8) Update existing CI contracts for the new version and add regression checks.
test_path = repo / "tests" / "test_source_contracts.py"
test = test_path.read_text(encoding="utf-8")
test = test.replace('self.assertEqual(info["CFBundleShortVersionString"], "1.58.0")', 'self.assertEqual(info["CFBundleShortVersionString"], "1.59.0")')
test = test.replace('self.assertEqual(info["CFBundleVersion"], "59")', 'self.assertEqual(info["CFBundleVersion"], "60")')
if "def test_fast_mail_and_instruction_integrity" not in test:
    insert = '''    def test_fast_mail_and_instruction_integrity(self):
        outlook = self.read("OutlookAccessibility.swift")
        delegate = self.read("AppDelegate.swift")
        panel = self.read("FloatingPanelController.swift")
        editor = self.read("RichTextMailEditor.swift")
        workspace = self.read("MailWorkspaceView.swift")
        client = self.read("OpenAIClient.swift")
        self.assertIn("fastMailText(in window:", outlook)
        self.assertIn('maxNodes: 4_500', outlook)
        self.assertIn('maxNodes: 6_000', outlook)
        self.assertIn("selectInstructionTextSoon(expectedText:", panel)
        self.assertIn("state.instruction == expectedText", panel)
        refresh = delegate[delegate.index("private func refreshMailContext()") : delegate.index("private func generateCurrentOutput()")]
        self.assertIn("instructionAtLoadStart", refresh)
        self.assertIn("userHasNotEdited", refresh)
        self.assertNotIn("selectInstructionTextSoon", refresh)
        self.assertIn("flushPendingEdits", editor)
        self.assertIn("replyZenCommitRichEditors", editor)
        self.assertGreaterEqual(workspace.count("replyZenCommitRichEditors"), 2)
        self.assertIn("USER INSTRUCTION is authoritative", client)

'''
    marker = '    def test_overlay_restores_after_workspace_close(self):\n'
    pos = test.index(marker)
    test = test[:pos] + insert + test[pos:]
test_path.write_text(test, encoding="utf-8")

verify_path = repo / "tests" / "verify_update.py"
verify = verify_path.read_text(encoding="utf-8")
verify = verify.replace("manifest['version'] == '1.58.0' and manifest['build'] == 59", "manifest['version'] == '1.59.0' and manifest['build'] == 60")
verify = verify.replace("'Replyzen-update-1.58.zip'", "'Replyzen-update-1.59.zip'")
verify = verify.replace("PASS: 1.58 version/build", "PASS: 1.59 version/build")
verify_path.write_text(verify, encoding="utf-8")

print("Migrated ReplyZen to 1.59.0 / build 60: faster mail loading and reliable editor instructions")
