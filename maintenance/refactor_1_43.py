#!/usr/bin/env python3
"""One-time, checked migration of the 1.42 source snapshot. Safe to run again."""
from __future__ import annotations
import hashlib
from pathlib import Path
import plistlib
import sys

EXPECTED = {
    "AppDelegate.swift": "cc6e187d5203703da48ece8b4fa6c85610b19236",
    "OpenAIClient.swift": "820658601b7a03392d4196cd16347c18dc093aa5",
    "OutlookToolbarButtonController.swift": "097d83ab54d003e57e0570e40b78a396ee2d8cd7",
    "OverlayView.swift": "684f0791a6c127c8fcbb47441866faa4ad7ece95",
}

def replace_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise RuntimeError("Expected one occurrence of: " + old[:90])
    return text.replace(old, new, 1)

def blob_sha(data: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()

def main(root: Path) -> None:
    app = root / "app"
    metadata = plistlib.loads((app / "Info.plist").read_bytes())
    if metadata["CFBundleShortVersionString"] == "1.43.0":
        if not (app / "ReplyZenBrand.swift").is_file() or not (app / "ResponseJSON.swift").is_file():
            raise RuntimeError("1.43 metadata without the expected source files")
        print("ReplyZen 1.43 migration already applied")
        return
    if metadata["CFBundleShortVersionString"] != "1.42.0":
        raise RuntimeError("Refusing to modify an unexpected app version")
    original = {}
    for name, expected in EXPECTED.items():
        data = (app / name).read_bytes()
        if blob_sha(data) != expected:
            raise RuntimeError("Source changed since review: " + name)
        original[name] = data.decode("utf-8")
    changed = {}

    # Keep resource names and identifiers stable; cache image loading and rendering.
    s = original["AppDelegate.swift"]
    first = s.index("    private func makeMenuBarTemplateIcon(from source: NSImage)")
    last = s.index("    private func configureHotKey()", first)
    template_function = s[first:last].replace("private func makeMenuBarTemplateIcon", "private static func makeMenuBarTemplateIcon", 1)
    s = s[:first] + s[last:]
    s = replace_once(s,
        '        if let url = Bundle.main.url(forResource: "ReplyzenLogo", withExtension: "png"),\n'
        '           let source = NSImage(contentsOf: url),\n'
        '           let image = makeMenuBarTemplateIcon(from: source) {',
        '        if let image = ReplyZenBrand.menuBarIcon {')
    s = s.replace('accessibilityDescription: "Replyzen"', 'accessibilityDescription: ReplyZenBrand.displayName')
    s = s.replace('item.button?.toolTip = "Replyzen"', 'item.button?.toolTip = ReplyZenBrand.displayName')
    s = s.replace('title: "Replyzen ', 'title: "ReplyZen ')
    changed["AppDelegate.swift"] = s
    changed["ReplyZenBrand.swift"] = '''import AppKit

/// User-visible branding is independent of the existing bundle/update identity.
enum ReplyZenBrand {
    static let displayName = "ReplyZen"
    static let logo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "ReplyzenLogo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
    static let menuBarIcon: NSImage? = logo.flatMap { makeMenuBarTemplateIcon(from: $0) }

''' + template_function + '}\n'

    s = original["OverlayView.swift"]
    if 'Text("Replyzen")' not in s:
        raise RuntimeError("Visible Replyzen heading not found")
    s = s.replace('Text("Replyzen")', 'Text(ReplyZenBrand.displayName)')
    s = s.replace('Text("Replyzen ', 'Text("ReplyZen ')
    s = s.replace('Button("Replyzen ', 'Button("ReplyZen ')
    s = replace_once(s,
        '            if let url = Bundle.main.url(forResource: "ReplyzenLogo", withExtension: "png"),\n'
        '               let image = NSImage(contentsOf: url) {',
        '            if let image = ReplyZenBrand.logo {')
    changed["OverlayView.swift"] = s

    s = original["OutlookToolbarButtonController.swift"]
    s = s.replace('import ApplicationServices\n', '')
    s = replace_once(s, '    private var isSuppressed = false\n',
        '    private var isSuppressed = false\n'
        '    private var isStarted = false\n'
        '    private var workspaceObservers: [NSObjectProtocol] = []\n')
    if s.count('    func start() {') != 1:
        raise RuntimeError("Unexpected toolbar structure")
    s = s[:s.index('    func start() {')] + (Path(__file__).parent / "ToolbarLifecycle.swift.txt").read_text()
    changed["OutlookToolbarButtonController.swift"] = s

    s = original["OpenAIClient.swift"]
    block = '''        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            let lines = cleaned.split(separator: "\\n", omittingEmptySubsequences: false)
            if lines.count >= 3 {
                cleaned = lines.dropFirst().dropLast().joined(separator: "\\n")
                if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("json") {
                    cleaned = String(cleaned.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
'''
    if s.count(block) != 4:
        raise RuntimeError("Expected four identical JSON normalizers")
    s = s.replace(block, '        let cleaned = ResponseJSON.cleanedText(text)\n')
    s = replace_once(s, 'final class OpenAIClient {\n',
        'final class OpenAIClient {\n'
        '    private let fileIOQueue = DispatchQueue(label: "com.lstoever.replyzen.file-io", qos: .userInitiated)\n\n')
    signature = '''    private func uploadFile(
        apiKey: String,
        url: URL,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
'''
    s = replace_once(s, signature, signature + '''        // Preparing a PDF/multipart body must never block the UI thread.
        fileIOQueue.async {
            self.prepareAndUploadFile(apiKey: apiKey, url: url, completion: completion)
        }
    }

    private func prepareAndUploadFile(
        apiKey: String,
        url: URL,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
''')
    s = replace_once(s, '        var body = Data()\n',
        '        var body = Data()\n        body.reserveCapacity(fileData.count + 1024)\n')
    changed["OpenAIClient.swift"] = s
    changed["ResponseJSON.swift"] = (Path(__file__).parent / "ResponseJSON.swift").read_text()

    metadata["CFBundleDisplayName"] = "ReplyZen"
    metadata["CFBundleShortVersionString"] = "1.43.0"
    metadata["CFBundleVersion"] = "44"
    # Validate every transformation before modifying the source snapshot.
    for name, text in changed.items():
        (app / name).write_text(text, encoding="utf-8")
    (app / "Info.plist").write_bytes(plistlib.dumps(metadata, sort_keys=False))
    print("Migrated 1.42 to ReplyZen 1.43; bundle/keychain/update identities preserved")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: refactor_1_43.py SOURCE_ROOT")
    main(Path(sys.argv[1]))
