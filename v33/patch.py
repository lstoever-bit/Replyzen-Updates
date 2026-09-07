from pathlib import Path
import re
import sys

root = Path(sys.argv[1])


def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f"{label} not found")
    return text.replace(old, new, 1)

# AppDelegate: detect DE/EN locally as soon as Outlook mail is read, make the
# main Replyzen overlay always open in Reply mode, and select the full suggested
# instruction so typing immediately replaces it.
p = root / "app" / "AppDelegate.swift"
s = p.read_text()

s = must_replace(
    s,
    "import AppKit\nimport ApplicationServices\n",
    "import AppKit\nimport ApplicationServices\nimport NaturalLanguage\n",
    "AppDelegate imports",
)

old_open = '''    private func openWorkspace() {\n        if isRunningFlow {\n            panel.show()\n            return\n        }\n\n        guard keychain.loadAPIKey() != nil else {\n'''
new_open = '''    private func openWorkspace() {\n        if isRunningFlow {\n            panel.show()\n            return\n        }\n\n        // The main Replyzen overlay is the normal reply workflow. If another\n        // mode was used previously, switch back to Reply and restore its default\n        // suggested command. The suggestion is selected below so the user can\n        // overwrite it by simply typing.\n        let wasReplyMode = state.outputMode == .reply\n        state.outputMode = .reply\n        if !wasReplyMode {\n            state.instruction = \"\"\n            state.selectedCommandName = \"Custom\"\n        }\n\n        guard keychain.loadAPIKey() != nil else {\n'''
s = must_replace(s, old_open, new_open, "openWorkspace reply reset")

old_show = '''        toolbarButton.setSuppressed(true)\n        prepareDefaultCommandIfNeeded()\n        state.stage = .instruction\n        panel.show(activate: true)\n\n        refreshMailContext()\n    }\n'''
new_show = '''        toolbarButton.setSuppressed(true)\n        prepareDefaultCommandIfNeeded()\n        state.stage = .instruction\n        panel.show(activate: true)\n        panel.selectInstructionTextSoon()\n\n        refreshMailContext()\n    }\n'''
s = must_replace(s, old_show, new_show, "openWorkspace select prompt")

old_success = '''                DispatchQueue.main.async {\n                    self.isLoadingMail = false\n                    self.activeSnapshot = snapshot\n                    self.state.mailText = mail\n                    self.state.mailStatus = .available\n                }\n'''
new_success = '''                DispatchQueue.main.async {\n                    self.isLoadingMail = false\n                    self.activeSnapshot = snapshot\n                    self.state.mailText = mail\n                    self.state.mailStatus = .available\n\n                    // Language selection is instant and local; it does not spend\n                    // another API request. We currently expose German and US English\n                    // in the UI, so only switch when one of those is confidently\n                    // recognized.\n                    if self.state.outputMode == .reply,\n                       let language = self.detectReplyLanguage(in: mail) {\n                        self.state.replyLanguage = language\n                    }\n\n                    // Keep the suggested instruction fully selected after the mail\n                    // context arrives, so the first keystroke replaces it.\n                    if self.state.outputMode == .reply {\n                        self.panel.selectInstructionTextSoon()\n                    }\n                }\n'''
s = must_replace(s, old_success, new_success, "refresh language detection")

anchor = '''    private func prepareDefaultCommandIfNeeded() {\n'''
helper = '''    private func detectReplyLanguage(in mailText: String) -> AppState.ReplyLanguage? {\n        let cleaned = mailText.trimmingCharacters(in: .whitespacesAndNewlines)\n        guard cleaned.count >= 8 else { return nil }\n\n        // The currently opened/latest message is normally at the beginning of the\n        // accessibility text. Limiting the sample reduces influence from older quoted\n        // messages in long bilingual threads.\n        let sample = String(cleaned.prefix(6_000))\n        let recognizer = NLLanguageRecognizer()\n        recognizer.processString(sample)\n\n        guard let language = recognizer.dominantLanguage else { return nil }\n        switch language {\n        case .german:\n            return .german\n        case .english:\n            return .usEnglish\n        default:\n            return nil\n        }\n    }\n\n'''
if anchor not in s:
    raise SystemExit("prepareDefaultCommandIfNeeded anchor not found")
s = s.replace(anchor, helper + anchor, 1)
p.write_text(s)

# FloatingPanelController: find the SwiftUI TextEditor backing NSTextView and
# select its whole current value once the panel is key.
p = root / "app" / "FloatingPanelController.swift"
s = p.read_text()
anchor = '''    func hide() {\n'''
selection = '''    func selectInstructionTextSoon() {\n        let delays: [TimeInterval] = [0.05, 0.16, 0.34]\n        for delay in delays {\n            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in\n                self?.selectInstructionTextIfPossible()\n            }\n        }\n    }\n\n    private func selectInstructionTextIfPossible() {\n        guard state.stage == .instruction, state.outputMode == .reply,\n              let root = panel.contentView else { return }\n\n        let expected = state.instruction\n        guard !expected.isEmpty else { return }\n\n        if let textView = findInstructionTextView(in: root, expectedText: expected) {\n            panel.makeKey()\n            panel.makeFirstResponder(textView)\n            textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))\n            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))\n        }\n    }\n\n    private func findInstructionTextView(in view: NSView, expectedText: String) -> NSTextView? {\n        if let textView = view as? NSTextView, textView.isEditable {\n            if textView.string == expectedText { return textView }\n        }\n        for child in view.subviews {\n            if let found = findInstructionTextView(in: child, expectedText: expectedText) {\n                return found\n            }\n        }\n        return nil\n    }\n\n'''
if anchor not in s:
    raise SystemExit("FloatingPanel hide anchor not found")
s = s.replace(anchor, selection + anchor, 1)
p.write_text(s)

# Version + build.
p = root / "app" / "Info.plist"
s = p.read_text()
s = must_replace(s, "<string>1.22.0</string>", "<string>1.23.0</string>", "Info version")
s = must_replace(s, "<string>23</string>", "<string>24</string>", "Info build")
p.write_text(s)

# Build script: link NaturalLanguage and publish 1.23 package/manifest.
p = root / "Build-CI.sh"
s = p.read_text()
s = re.sub(r"Replyzen-update-1\.\d+\.zip", "Replyzen-update-1.23.zip", s)
s = s.replace("-framework PDFKit -framework Vision \\", "-framework PDFKit -framework Vision -framework NaturalLanguage \\")
s = re.sub(
    r'"notes": ".*?"',
    '"notes": "Replyzen 1.23: Beim Klick auf Replyzen wird die Sprache der geöffneten Mail lokal erkannt und Deutsch/US English automatisch vorausgewählt. Der vorgeschlagene Reply-Prompt ist vollständig markiert, sodass Tippen ihn sofort ersetzt."',
    s,
    count=1,
)
p.write_text(s)
