#!/usr/bin/env python3
"""ReplyZen 1.64: make the native rich-text editor wrap at its visible edge."""
from pathlib import Path
import json
import plistlib
import sys

root = Path(sys.argv[1])
repo = root.parent
app = root / "app"


def replace_once(text: str, before: str, after: str, label: str) -> str:
    count = text.count(before)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}")
    return text.replace(before, after, 1)


info_path = app / "Info.plist"
info = plistlib.loads(info_path.read_bytes())
if info.get("CFBundleShortVersionString") == "1.64.0" and str(info.get("CFBundleVersion")) == "65":
    editor = (app / "RichTextMailEditor.swift").read_text(encoding="utf-8")
    required = [
        "scrollView.contentView.bounds.width",
        "textView.maxSize = NSSize(width: width",
        "NSView.frameDidChangeNotification",
        "lineBreakMode = .byWordWrapping",
    ]
    if not all(token in editor for token in required):
        raise SystemExit("ReplyZen reports 1.64 but the wrapping fix is incomplete")
    print("ReplyZen 1.64 migration already applied")
    raise SystemExit(0)
if info.get("CFBundleShortVersionString") != "1.63.0" or str(info.get("CFBundleVersion")) != "64":
    raise SystemExit("Unexpected ReplyZen source version; refusing to modify")

editor_path = app / "RichTextMailEditor.swift"
editor = editor_path.read_text(encoding="utf-8")

editor = replace_once(
    editor,
'''    private var keyMonitor: Any?\n    @Published private(set) var zoomPercent: Int = {\n''',
'''    private var keyMonitor: Any?\n    private var wrapObservers: [NSObjectProtocol] = []\n    private var wrapWorkItem: DispatchWorkItem?\n    private var lastWrapWidth: CGFloat = 0\n    private var isNormalizingParagraphStyles = false\n    @Published private(set) var zoomPercent: Int = {\n''',
    "wrapping state",
)

editor = replace_once(
    editor,
'''    deinit {\n        if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }\n        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }\n    }\n''',
'''    deinit {\n        if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }\n        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }\n        wrapWorkItem?.cancel()\n        for observer in wrapObservers { NotificationCenter.default.removeObserver(observer) }\n    }\n''',
    "wrapping observer cleanup",
)

editor = replace_once(
    editor,
'''        self.scrollView = scrollView\n        scrollView.allowsMagnification = true\n''',
'''        self.scrollView = scrollView\n        installWrapObservers(for: scrollView)\n        scrollView.allowsMagnification = true\n''',
    "install wrapping observers",
)

editor = replace_once(
    editor,
'''            ) { [weak self] _ in self?.schedulePublish() }\n''',
'''            ) { [weak self] _ in\n                self?.normalizeParagraphWrapping()\n                self?.scheduleWrapUpdate()\n                self?.schedulePublish()\n            }\n''',
    "normalize wrapping after edits",
)

editor = replace_once(
    editor,
'''        view.textContainerInset = NSSize(width: 10, height: 10)\n        view.isVerticallyResizable = true\n        view.isHorizontallyResizable = false\n        view.autoresizingMask = [.width]\n        view.textContainer?.widthTracksTextView = true\n    }\n''',
'''        view.textContainerInset = NSSize(width: 10, height: 10)\n        view.isVerticallyResizable = true\n        view.isHorizontallyResizable = false\n        view.autoresizingMask = [.width]\n        view.minSize = NSSize(width: 0, height: 0)\n        view.textContainer?.widthTracksTextView = true\n        normalizeParagraphWrapping()\n    }\n''',
    "native editor width configuration",
)

old_wrap = '''    func refreshWrapping() {\n        updateWrapWidth()\n    }\n\n    private func updateWrapWidth() {\n        guard let scrollView, let textView else { return }\n        let scale = max(CGFloat(1.0), scrollView.magnification)\n        let width = max(CGFloat(120), scrollView.contentSize.width / scale)\n        textView.isHorizontallyResizable = false\n        textView.autoresizingMask = [.width]\n        textView.textContainer?.widthTracksTextView = true\n        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)\n        var frame = textView.frame\n        frame.size.width = width\n        frame.size.height = max(frame.size.height, scrollView.contentSize.height / scale)\n        textView.frame = frame\n        var origin = scrollView.contentView.bounds.origin\n        origin.x = 0\n        scrollView.contentView.scroll(to: origin)\n        scrollView.reflectScrolledClipView(scrollView.contentView)\n    }\n'''

new_wrap = '''    func refreshWrapping() {\n        scheduleWrapUpdate()\n    }\n\n    private func installWrapObservers(for scrollView: NSScrollView) {\n        for observer in wrapObservers { NotificationCenter.default.removeObserver(observer) }\n        wrapObservers.removeAll()\n\n        scrollView.postsFrameChangedNotifications = true\n        scrollView.contentView.postsFrameChangedNotifications = true\n        let center = NotificationCenter.default\n        for view in [scrollView as NSView, scrollView.contentView as NSView] {\n            wrapObservers.append(center.addObserver(\n                forName: NSView.frameDidChangeNotification,\n                object: view,\n                queue: .main\n            ) { [weak self] _ in\n                self?.scheduleWrapUpdate()\n            })\n        }\n    }\n\n    private func scheduleWrapUpdate() {\n        wrapWorkItem?.cancel()\n        let item = DispatchWorkItem { [weak self] in self?.updateWrapWidth() }\n        wrapWorkItem = item\n        DispatchQueue.main.async(execute: item)\n    }\n\n    private func normalizeParagraphWrapping() {\n        guard !isNormalizingParagraphStyles, let textView else { return }\n        isNormalizingParagraphStyles = true\n        defer { isNormalizingParagraphStyles = false }\n\n        if let storage = textView.textStorage, storage.length > 0 {\n            let fullRange = NSRange(location: 0, length: storage.length)\n            storage.beginEditing()\n            storage.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in\n                guard let current = value as? NSParagraphStyle,\n                      current.lineBreakMode != .byWordWrapping,\n                      let style = current.mutableCopy() as? NSMutableParagraphStyle else { return }\n                style.lineBreakMode = .byWordWrapping\n                storage.addAttribute(.paragraphStyle, value: style, range: range)\n            }\n            storage.endEditing()\n        }\n\n        let typingStyle = ((textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)\n            ?? NSMutableParagraphStyle()\n        typingStyle.lineBreakMode = .byWordWrapping\n        textView.typingAttributes[.paragraphStyle] = typingStyle\n    }\n\n    private func updateWrapWidth() {\n        guard let scrollView, let textView else { return }\n        scrollView.layoutSubtreeIfNeeded()\n\n        // NSClipView.bounds is expressed in document coordinates, so at 130%/150%\n        // zoom it already represents the exact width that is visibly available to\n        // the text. Using NSScrollView.contentSize here made the document wider than\n        // the visible editor and caused the delayed wrap/horizontal scrolling bug.\n        let visibleWidth = scrollView.contentView.bounds.width\n        let scale = max(CGFloat(1.0), scrollView.magnification)\n        let fallbackWidth = scrollView.contentSize.width / scale\n        let width = max(CGFloat(120), visibleWidth > 1 ? visibleWidth : fallbackWidth)\n\n        textView.isHorizontallyResizable = false\n        textView.autoresizingMask = [.width]\n        textView.minSize = NSSize(width: 0, height: 0)\n        textView.maxSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)\n        textView.textContainer?.widthTracksTextView = true\n        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)\n\n        if abs(textView.frame.width - width) > 0.5 || abs(lastWrapWidth - width) > 0.5 {\n            var frame = textView.frame\n            frame.size.width = width\n            frame.size.height = max(frame.size.height, scrollView.contentView.bounds.height)\n            textView.frame = frame\n            lastWrapWidth = width\n        }\n\n        normalizeParagraphWrapping()\n        if let container = textView.textContainer {\n            textView.layoutManager?.ensureLayout(for: container)\n        }\n\n        // There is intentionally no horizontal document range. Keep x pinned to\n        // zero as a final guard so the insertion caret always remains visible.\n        var origin = scrollView.contentView.bounds.origin\n        if origin.x != 0 {\n            origin.x = 0\n            scrollView.contentView.scroll(to: origin)\n            scrollView.reflectScrolledClipView(scrollView.contentView)\n        }\n    }\n'''
editor = replace_once(editor, old_wrap, new_wrap, "visible-edge wrapping implementation")

editor = replace_once(
    editor,
'''        scroll.hasVerticalScroller = true\n        scroll.hasHorizontalScroller = false\n        scroll.horizontalScrollElasticity = .none\n''',
'''        scroll.hasVerticalScroller = true\n        scroll.hasHorizontalScroller = false\n        scroll.horizontalScrollElasticity = .none\n        scroll.contentView.postsFrameChangedNotifications = true\n''',
    "clip-view resize notification",
)

editor_path.write_text(editor, encoding="utf-8")

# Version.
info["CFBundleShortVersionString"] = "1.64.0"
info["CFBundleVersion"] = "65"
info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=False))

# Extend the existing source contract with the actual inner TextKit constraints.
contracts_path = repo / "tests" / "test_source_contracts.py"
contracts = contracts_path.read_text(encoding="utf-8")
contracts = contracts.replace('self.assertEqual(info["CFBundleShortVersionString"], "1.63.0")', 'self.assertEqual(info["CFBundleShortVersionString"], "1.64.0")')
contracts = contracts.replace('self.assertEqual(info["CFBundleVersion"], "64")', 'self.assertEqual(info["CFBundleVersion"], "65")')
needle = '''        self.assertIn("widthTracksTextView = true", editor)\n'''
addition = '''        self.assertIn("widthTracksTextView = true", editor)\n        self.assertIn("scrollView.contentView.bounds.width", editor)\n        self.assertIn("textView.minSize = NSSize(width: 0", editor)\n        self.assertIn("textView.maxSize = NSSize(width: width", editor)\n        self.assertIn("NSView.frameDidChangeNotification", editor)\n        self.assertIn("postsFrameChangedNotifications = true", editor)\n        self.assertIn("lineBreakMode = .byWordWrapping", editor)\n        self.assertIn("origin.x = 0", editor)\n'''
contracts = replace_once(contracts, needle, addition, "wrapping source contract")
contracts_path.write_text(contracts, encoding="utf-8")

verify_path = repo / "tests" / "verify_update.py"
verify = verify_path.read_text(encoding="utf-8")
verify = verify.replace("manifest['version'] == '1.63.0' and manifest['build'] == 64", "manifest['version'] == '1.64.0' and manifest['build'] == 65")
verify = verify.replace("manifest['download_url'] == 'Replyzen-update-1.63.zip'", "manifest['download_url'] == 'Replyzen-update-1.64.zip'")
verify = verify.replace("PASS: 1.63 version/build", "PASS: 1.64 version/build")
verify_path.write_text(verify, encoding="utf-8")

notes_de = "ReplyZen 1.64: Der Rich-Text-Editor bricht Text jetzt direkt an der tatsächlich sichtbaren rechten Kante um. Die innere AppKit/TextKit-Fläche wird bei Fenstergröße und Editor-Zoom an die sichtbare Breite gebunden, kann nicht mehr horizontal wachsen und hält die horizontale Scrollposition auf null. Auch lange Wörter, URLs, eingefügter und formatierter Text bleiben innerhalb des Editors; die bestehende WYSIWYG-, Zoom- und Mail-Logik bleibt unverändert."
notes_en = "ReplyZen 1.64: The rich-text editor now wraps text exactly at the visible right edge. Its internal AppKit/TextKit surface follows the real visible width across window resizing and editor zoom, cannot grow horizontally, and keeps horizontal scroll position at zero. Long words, URLs, pasted content and formatted text remain inside the editor; existing WYSIWYG, zoom and mail behavior is unchanged."
notes_es = "ReplyZen 1.64: El editor de texto enriquecido ahora ajusta el texto exactamente en el borde derecho visible. La superficie interna AppKit/TextKit sigue el ancho visible real al cambiar el tamaño de la ventana y el zoom, no puede crecer horizontalmente y mantiene la posición horizontal en cero. Las palabras largas, URL, contenido pegado y texto con formato permanecen dentro del editor; el comportamiento WYSIWYG, zoom y correo existente no cambia."
(root / "Release-notes.txt").write_text(notes_de + "\n", encoding="utf-8")
(root / "Release-notes.localized.json").write_text(json.dumps({"de": notes_de, "en-US": notes_en, "es": notes_es}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

print("Migrated ReplyZen to 1.64.0 / build 65")
