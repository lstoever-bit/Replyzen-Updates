#!/usr/bin/env python3
"""Regression guards for branding, app identity and existing feature paths."""
from pathlib import Path
import plistlib
import sys
import unittest

ROOT = Path(sys.argv[1])
sys.argv = [sys.argv[0]]
APP = ROOT / "app"

class SourceContracts(unittest.TestCase):
    def read(self, name):
        return (APP / name).read_text(encoding="utf-8")

    def test_app_identity_and_version(self):
        info = plistlib.loads((APP / "Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "com.lstoever.replyzen")
        self.assertEqual(info["CFBundleExecutable"], "Replyzen")
        self.assertEqual(info["CFBundleName"], "Replyzen")
        self.assertEqual(info["CFBundleDisplayName"], "ReplyZen")
        self.assertEqual(info["CFBundleShortVersionString"], "1.43.0")
        self.assertEqual(info["CFBundleVersion"], "44")

    def test_visible_header_and_cached_logo(self):
        view = self.read("OverlayView.swift")
        brand = self.read("ReplyZenBrand.swift")
        self.assertIn('static let displayName = "ReplyZen"', brand)
        self.assertIn('Text(ReplyZenBrand.displayName)', view)
        self.assertNotIn('Text("Replyzen")', view)
        self.assertIn('if let image = ReplyZenBrand.logo', view)
        self.assertNotIn('NSImage(contentsOf:', view)
        self.assertIn('static let menuBarIcon', brand)
        self.assertNotIn('private func makeMenuBarTemplateIcon', self.read("AppDelegate.swift"))

    def test_toolbar_lifecycle(self):
        toolbar = self.read("OutlookToolbarButtonController.swift")
        self.assertIn('frontmostApplication?.bundleIdentifier == "com.microsoft.Outlook"', toolbar)
        self.assertIn('isStarted && !isSuppressed', toolbar)
        self.assertIn('newTimer.tolerance = 0.07', toolbar)
        self.assertIn('workspaceObservers.removeAll()', toolbar)
        self.assertIn('if panel.frame.origin != origin', toolbar)
        self.assertNotIn('timer!', toolbar)
        self.assertNotIn('runningApplications.first', toolbar)
        for action in ['new', 'reply', 'replyAll', 'forward', 'cancel', 'calendar', 'payment']:
            self.assertIn(action + 'Action?()', toolbar)

    def test_existing_outlook_integration(self):
        app = self.read("AppDelegate.swift")
        for flow in ['openNewMailWorkspace', 'openReplyWorkspace', 'openForwardWorkspace',
                     'quickDecline', 'createCalendarFromOverlay', 'createPaymentFromOverlay']:
            self.assertIn(flow + '(', app)
        self.assertIn('openSelectedMessageWindowIfNeeded', self.read("OutlookAccessibility.swift"))

    def test_json_and_upload_pipeline(self):
        client = self.read("OpenAIClient.swift")
        self.assertEqual(client.count('ResponseJSON.cleanedText(text)'), 4)
        self.assertNotIn('var cleaned = text.trimmingCharacters', client)
        self.assertIn('fileIOQueue.async {', client)
        self.assertIn('body.reserveCapacity(fileData.count + 1024)', client)
        self.assertIn('url.pathExtension.lowercased() == "pdf"', client)
        self.assertIn('"store": false', client)
        self.assertIn('collected.forEach { self.deleteUploadedFile', client)
        self.assertIn('fileIDs.forEach { self.deleteUploadedFile', client)
        self.assertIn('Never initiate, authorize or imply that a payment has been made.', client)

    def test_release_build(self):
        build = (ROOT / "Build-CI.sh").read_text()
        self.assertIn('-O -whole-module-optimization', build)
        self.assertIn('CFBundleShortVersionString', build)
        self.assertIn('json.dumps', build)
        self.assertIn('codesign --verify', build)
        self.assertNotIn('Replyzen-update-1.42', build)

if __name__ == "__main__":
    unittest.main(verbosity=2)
