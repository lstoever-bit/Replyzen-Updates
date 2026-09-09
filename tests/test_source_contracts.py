#!/usr/bin/env python3
from pathlib import Path
import plistlib
import sys
import unittest
ROOT = Path(sys.argv[1]); sys.argv = [sys.argv[0]]; APP = ROOT / "app"

class SourceContracts(unittest.TestCase):
    def read(self, name): return (APP / name).read_text(encoding="utf-8")
    def test_identity_and_version(self):
        info = plistlib.loads((APP / "Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "com.lstoever.replyzen")
        self.assertEqual(info["CFBundleDisplayName"], "ReplyZen")
        self.assertEqual(info["CFBundleShortVersionString"], "1.56.0")
        self.assertEqual(info["CFBundleVersion"], "57")
    def test_payment_is_removed_from_active_code(self):
        self.assertFalse((APP / "AttachmentTextExtractor.swift").exists())
        swift = "\n".join(p.read_text(encoding="utf-8") for p in APP.glob("*.swift"))
        lowered = swift.lower()
        for token in ["payment", "überweisung", "banknote", "paymentpreview", "paymentrecipient"]:
            self.assertNotIn(token, lowered)
    def test_outlook_overlay_has_six_actions(self):
        toolbar = self.read("OutlookToolbarButtonController.swift")
        self.assertIn("NSSize(width: 282, height: 34)", toolbar)
        for action in ["new", "reply", "replyAll", "forward", "cancel", "calendar"]:
            self.assertIn(action + "Action?()", toolbar)
        self.assertNotIn("paymentAction", toolbar)
    def test_fresh_hosting_tree_on_hidden_open(self):
        panel = self.read("FloatingPanelController.swift")
        self.assertIn("private func installFreshHostingRoot()", panel)
        self.assertIn("if !panel.isVisible", panel)
        self.assertIn("NSHostingController(rootView: OverlayView(state: state))", panel)
        self.assertIn("resizeForCurrentState(animated: false, centered: true)", panel)
        self.assertNotIn("defaults.set(", panel)
    def test_stable_native_wysiwyg_wrapper(self):
        editor = self.read("RichTextMailEditor.swift")
        toolbar = self.read("EditorToolbar.swift")
        package = (ROOT / "Package.swift").read_text(encoding="utf-8")
        self.assertIn("rich-editor-swiftui.git", package)
        self.assertIn('exact: "1.1.1"', package)
        self.assertIn("import RichEditorSwiftUI", editor)
        self.assertIn("NSViewRepresentable", editor)
        self.assertIn("RichTextView.scrollableTextView()", editor)
        self.assertNotIn("RichTextEditor(", editor)
        self.assertNotIn("RichEditorState", editor)
        self.assertIn("adapter.toggleBold", toolbar)
        self.assertIn("adapter.toggleItalic", toolbar)
        self.assertIn("MailTypography.normalizeFonts", editor)
        self.assertIn("scrollView.allowsMagnification = true", editor)
        self.assertIn("adapter.attachZoom(to: scroll)", editor)
        self.assertIn("adapter.zoomPercent", toolbar)
        self.assertIn("Editor-Zoom", toolbar)
    def test_existing_mail_calendar_paths(self):
        delegate = self.read("AppDelegate.swift")
        for flow in ["openNewMailWorkspace", "openReplyWorkspace", "openForwardWorkspace", "quickDecline", "createCalendarFromOverlay"]:
            self.assertIn(flow + "(", delegate)
        state = self.read("AppState.swift")
        for mode in ["case reply", "case newMail", "case forward", "case calendar"]:
            self.assertIn(mode, state)
    def test_json_pipeline(self):
        client = self.read("OpenAIClient.swift")
        self.assertEqual(client.count("ResponseJSON.cleanedText(text)"), 3)
        self.assertNotIn("PaymentSuggestion", client)
        self.assertNotIn("uploadFile(", client)
        self.assertNotIn("fileIOQueue", client)
        self.assertIn('"store": false', client)
    def test_typography_contract(self):
        typography = self.read("MailTypography.swift")
        self.assertIn("static let pointSize: CGFloat = 10.5", typography)
        self.assertIn('static let family = "Calibri Light"', typography)
        self.assertIn("MailTypography.baseFont", self.read("RichTextMailEditor.swift"))
    def test_new_mail_subject_uses_native_keyboard_commit(self):
        delegate = self.read("AppDelegate.swift")
        keyboard = self.read("KeyboardController.swift")
        self.assertIn("func sendCommandA()", keyboard)
        self.assertIn("self.keyboard.sendCommandA()", delegate)
        self.assertIn("self.keyboard.sendCommandV()", delegate)
        self.assertIn("self.keyboard.sendTab()", delegate)
        self.assertNotIn("setComposeSubjectValue(subject)", delegate)

    def test_window_position_contract(self):
        panel = self.read("FloatingPanelController.swift")
        self.assertIn("panel.isMovable = true", panel)
        self.assertIn("panel.isRestorable = false", panel)
        self.assertIn('panel.setFrameAutosaveName("")', panel)
        self.assertIn('defaults.removeObject(forKey: "Replyzen.FloatingPanel.Frame.v1")', panel)
        toolbar = self.read("OutlookToolbarButtonController.swift")
        self.assertIn("defaults.set(Double(toolbarOffset.x)", toolbar)
        self.assertIn("defaults.set(Double(toolbarOffset.y)", toolbar)

if __name__ == "__main__": unittest.main(verbosity=2)
