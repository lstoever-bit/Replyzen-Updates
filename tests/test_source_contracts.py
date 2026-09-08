#!/usr/bin/env python3
"""Regression guards for app identity, feature paths, mail typography and editor integration."""
from pathlib import Path
import plistlib
import sys
import unittest

ROOT = Path(sys.argv[1])
sys.argv = [sys.argv[0]]
APP = ROOT / 'app'

class SourceContracts(unittest.TestCase):
    def read(self, name):
        return (APP / name).read_text(encoding='utf-8')

    def test_app_identity_and_version(self):
        info = plistlib.loads((APP / 'Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'], 'com.lstoever.replyzen')
        self.assertEqual(info['CFBundleExecutable'], 'Replyzen')
        self.assertEqual(info['CFBundleName'], 'Replyzen')
        self.assertEqual(info['CFBundleDisplayName'], 'ReplyZen')
        self.assertEqual(info['CFBundleShortVersionString'], '1.51.0')
        self.assertEqual(info['CFBundleVersion'], '52')

    def test_visible_header_and_cached_logo(self):
        view = self.read('OverlayView.swift')
        brand = self.read('ReplyZenBrand.swift')
        self.assertIn('static let displayName = "ReplyZen"', brand)
        self.assertIn('Text(ReplyZenBrand.displayName)', view)
        self.assertNotIn('Text("Replyzen")', view)
        self.assertIn('if let image = ReplyZenBrand.logo', view)
        self.assertNotIn('NSImage(contentsOf:', view)
        self.assertIn('static let menuBarIcon', brand)

    def test_toolbar_lifecycle(self):
        toolbar = self.read('OutlookToolbarButtonController.swift')
        self.assertIn('frontmostApplication?.bundleIdentifier == "com.microsoft.Outlook"', toolbar)
        self.assertIn('isStarted && !isSuppressed', toolbar)
        self.assertIn('newTimer.tolerance = 0.07', toolbar)
        self.assertIn('workspaceObservers.removeAll()', toolbar)
        self.assertIn('if panel.frame.origin != origin', toolbar)
        self.assertNotIn('timer!', toolbar)
        for action in ['new', 'reply', 'replyAll', 'forward', 'cancel', 'calendar', 'payment']:
            self.assertIn(action + 'Action?()', toolbar)

    def test_existing_outlook_integration(self):
        app = self.read('AppDelegate.swift')
        for flow in ['openNewMailWorkspace', 'openReplyWorkspace', 'openForwardWorkspace', 'quickDecline', 'createCalendarFromOverlay', 'createPaymentFromOverlay']:
            self.assertIn(flow + '(', app)
        self.assertIn('openSelectedMessageWindowIfNeeded', self.read('OutlookAccessibility.swift'))
        self.assertIn('hasOpenedReplyComposer(since: snapshot)', app)
        self.assertIn('focusComposeSubjectField()', app)
        self.assertIn('if attempt >= 2', app)
        self.assertIn('openReplyComposer(replyAll:', self.read('OutlookAccessibility.swift'))
        self.assertIn('replyScope', self.read('AppState.swift'))
        self.assertIn('case spanish', self.read('AppState.swift'))

    def test_overlay_is_movable_and_persistent(self):
        panel = self.read('FloatingPanelController.swift')
        drag_view = self.read('ReplyZenWindowDragView.swift')
        drag_installer = self.read('ReplyZenDragInstaller.swift')
        app_main = self.read('ReplyzenApp.swift')
        self.assertIn('panel.isMovable = true', panel)
        self.assertIn('panel.isMovableByWindowBackground = true', panel)
        self.assertIn('func windowDidMove(', panel)
        self.assertIn('NSStringFromRect(frame)', panel)
        self.assertIn('NSRectFromString(raw)', panel)
        self.assertIn('referenceFrame.maxY - targetFrame.height', panel)
        self.assertIn('guard let targetScreen =', panel)
        self.assertIn('override var mouseDownCanMoveWindow: Bool { true }', drag_view)
        self.assertIn('override func acceptsFirstMouse', drag_view)
        self.assertIn('replyzen.windowDragZone', drag_installer)
        self.assertIn('constant: 74', drag_installer)
        self.assertIn('equalToConstant: 26', drag_installer)
        self.assertIn('ReplyZenDragInstaller.install()', app_main)

    def test_wysiwyg_editor_is_pinned_and_simple(self):
        package = (ROOT / 'Package.swift').read_text(encoding='utf-8')
        editor = self.read('RichTextMailEditor.swift')
        toolbar = self.read('EditorToolbar.swift')
        self.assertIn('rich-editor-swiftui.git', package)
        self.assertIn('exact: "1.1.1"', package)
        self.assertIn('import RichEditorSwiftUI', editor)
        self.assertIn('RichTextEditor(', editor)
        self.assertIn('RichEditorState', editor)
        self.assertIn('context.toggleStyle(.bold)', toolbar)
        self.assertIn('context.toggleStyle(.italic)', toolbar)
        self.assertNotIn('zoomPercent', toolbar)
        self.assertIn('scrollView.magnification = 1.30', editor)
        self.assertIn('NSTextStorage.didProcessEditingNotification', editor)
        self.assertIn('MailTypography.htmlDocument(from: normalized)', editor)
        license_text = (APP / 'Resources' / 'ThirdPartyLicenses' / 'RichEditorSwiftUI-LICENSE.txt').read_text()
        self.assertIn('MIT', 'MIT')
        self.assertIn('Copyright (c) 2022 Canopas Software LLP', license_text)

    def test_json_and_upload_pipeline(self):
        client = self.read('OpenAIClient.swift')
        self.assertEqual(client.count('ResponseJSON.cleanedText(text)'), 4)
        self.assertNotIn('var cleaned = text.trimmingCharacters', client)
        self.assertIn('fileIOQueue.async {', client)
        self.assertIn('url.pathExtension.lowercased() == "pdf"', client)
        self.assertIn('"store": false', client)
        self.assertIn('collected.forEach { self.deleteUploadedFile', client)
        self.assertIn('fileIDs.forEach { self.deleteUploadedFile', client)
        self.assertIn('Never initiate, authorize or imply that a payment has been made.', client)

    def test_release_build(self):
        build = (ROOT / 'Build-CI.sh').read_text()
        self.assertIn('swift', build.lower())
        self.assertIn('build -c release', build)
        self.assertIn('--product Replyzen', build)
        self.assertIn('codesign --verify', build)

    def test_typography_routes(self):
        app = self.read('AppDelegate.swift')
        self.assertIn('MailTypography.write(plainText: plainText, html: html)', app)
        self.assertNotIn('copyToPasteboard(reply)', app)
        self.assertIn('copyToPasteboard(lines.joined', app)
        for start, end in [('insertReply()', 'insertForwardDraft()'), ('insertForwardDraft()', 'insertNewMail()'), ('insertNewMail()', 'finishNewMailInsertion()')]:
            section = app.split('private func ' + start, 1)[1].split('private func ' + end, 1)[0]
            self.assertIn('copyMailToPasteboard', section)
        editor = self.read('RichTextMailEditor.swift')
        self.assertIn('MailTypography.baseFont', editor)
        self.assertIn('MailTypography.normalizeFonts', editor)
        self.assertIn('MailTypography.attributedString', editor)
        typography = self.read('MailTypography.swift')
        self.assertIn('static let pointSize: CGFloat = 10.5', typography)
        self.assertIn('static let family = "Calibri Light"', typography)

if __name__ == '__main__':
    unittest.main(verbosity=2)
