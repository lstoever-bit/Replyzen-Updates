#!/usr/bin/env python3
"""Regression guards for app identity, feature paths and outgoing typography."""
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
        self.assertEqual(info['CFBundleShortVersionString'], '1.44.0')
        self.assertEqual(info['CFBundleVersion'], '45')

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
        self.assertIn('-O -whole-module-optimization', build)
        self.assertIn('json.dumps', build)
        self.assertIn('codesign --verify', build)

    def test_typography_routes(self):
        app = self.read('AppDelegate.swift')
        self.assertIn('MailTypography.write(plainText: plainText, html: html)', app)
        self.assertNotIn('copyToPasteboard(reply)', app)
        self.assertIn('copyToPasteboard(lines.joined', app)  # payment export remains plain text
        for start, end in [('insertReply()', 'insertForwardDraft()'), ('insertForwardDraft()', 'insertNewMail()'), ('insertNewMail()', 'finishNewMailInsertion()')]:
            section = app.split('private func ' + start, 1)[1].split('private func ' + end, 1)[0]
            self.assertIn('copyMailToPasteboard', section)
        editor = self.read('RichTextMailEditor.swift')
        self.assertNotIn('NSFont.systemFont(ofSize: 14)', editor)
        self.assertIn('MailTypography.baseFont', editor)
        self.assertIn('MailTypography.normalizeFonts', editor)
        self.assertIn('MailTypography.attributedString', editor)

if __name__ == '__main__':
    unittest.main(verbosity=2)
