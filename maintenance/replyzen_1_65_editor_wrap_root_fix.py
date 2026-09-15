#!/usr/bin/env python3
"""ReplyZen 1.65: remove scroll-view magnification from the editor and zoom fonts instead.

This keeps visual zoom display-only while letting AppKit/TextKit use a normal,
non-magnified document width, so wrapping happens at the visible editor edge.
"""
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
editor_path = app / "RichTextMailEditor.swift"
editor = editor_path.read_text(encoding="utf-8")

if info.get("CFBundleShortVersionString") == "1.65.0" and str(info.get("CFBundleVersion")) == "66":
    required = [
        "scrollView.allowsMagnification = false",
        "scrollView.magnification = 1.0",
        "private func displayFont(preserving source: NSFont?)",
        "private func applyDisplayZoom()",
        "scrollView.documentVisibleRect.width",
        "textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude",
    ]
    if not all(token in editor for token in required):
        raise SystemExit("ReplyZen reports 1.65 but the root wrapping fix is incomplete")
    print("ReplyZen 1.65 migration already applied")
    raise SystemExit(0)

if info.get("CFBundleShortVersionString") != "1.64.0" or str(info.get("CFBundleVersion")) != "65":
    raise SystemExit("Unexpected ReplyZen source version; refusing to modify")

editor = replace_once(editor, "    private var zoomObservation: NSKeyValueObservation?\n", "", "remove magnification observation")

old_zoom = '''    func attachZoom(to scrollView: NSScrollView) {\n        if self.scrollView === scrollView { return }\n        self.scrollView = scrollView\n        installWrapObservers(for: scrollView)\n        scrollView.allowsMagnification = true\n        scrollView.minMagnification = 1.0\n        scrollView.maxMagnification = 1.8\n        scrollView.magnification = CGFloat(zoomPercent) / 100.0\n        zoomObservation = scrollView.observe(\\.magnification, options: [.new]) { [weak self, weak scrollView] _, _ in\n            DispatchQueue.main.async {\n                guard let self, let scrollView, self.scrollView === scrollView else { return }\n                let percent = Int((scrollView.magnification * 100).rounded())\n                if percent != self.zoomPercent { self.zoomPercent = percent }\n                self.updateWrapWidth()\n            }\n        }\n    }\n\n    func setZoom(percent: Int) {\n        guard let scrollView else { return }\n        let clamped = min(180, max(100, percent))\n        scrollView.magnification = CGFloat(clamped) / 100.0\n        zoomPercent = clamped\n        UserDefaults.standard.set(clamped, forKey: "ReplyZen.EditorZoomPercent")\n        updateWrapWidth()\n    }\n'''
new_zoom = '''    func attachZoom(to scrollView: NSScrollView) {\n        if self.scrollView === scrollView { return }\n        self.scrollView = scrollView\n        installWrapObservers(for: scrollView)\n\n        // NSScrollView magnification creates a zoomed document viewport. That is\n        // useful for canvases, but wrong for a mail composer because the logical\n        // text width can extend beyond the visible Rich Text Box. Keep TextKit at\n        // 1:1 and implement ReplyZen's display-only zoom through font rendering.\n        scrollView.allowsMagnification = false\n        scrollView.magnification = 1.0\n        applyDisplayZoom()\n        scheduleWrapUpdate()\n    }\n\n    func setZoom(percent: Int) {\n        let clamped = min(180, max(100, percent))\n        guard clamped != zoomPercent else { return }\n        zoomPercent = clamped\n        UserDefaults.standard.set(clamped, forKey: "ReplyZen.EditorZoomPercent")\n        applyDisplayZoom()\n        updateWrapWidth()\n    }\n\n    private func displayFont(preserving source: NSFont?) -> NSFont {\n        let normalized = MailTypography.font(preserving: source)\n        let size = MailTypography.pointSize * CGFloat(zoomPercent) / 100.0\n        return NSFont(descriptor: normalized.fontDescriptor, size: size) ?? normalized\n    }\n\n    private func applyDisplayZoom() {\n        guard let textView else { return }\n        let wasApplyingExternalValue = isApplyingExternalValue\n        isApplyingExternalValue = true\n\n        if let storage = textView.textStorage, storage.length > 0 {\n            let fullRange = NSRange(location: 0, length: storage.length)\n            var changes: [(NSRange, NSFont)] = []\n            storage.enumerateAttribute(.font, in: fullRange) { value, range, _ in\n                let old = value as? NSFont\n                let desired = displayFont(preserving: old)\n                if old?.fontName != desired.fontName || abs((old?.pointSize ?? 0) - desired.pointSize) > 0.01 {\n                    changes.append((range, desired))\n                }\n            }\n            if !changes.isEmpty {\n                storage.beginEditing()\n                for (range, font) in changes { storage.addAttribute(.font, value: font, range: range) }\n                storage.endEditing()\n            }\n        }\n\n        textView.font = displayFont(preserving: textView.font)\n        textView.typingAttributes[.font] = displayFont(preserving: textView.typingAttributes[.font] as? NSFont)\n        isApplyingExternalValue = wasApplyingExternalValue\n        textView.needsDisplay = true\n    }\n'''
editor = replace_once(editor, old_zoom, new_zoom, "replace scroll magnification with display font zoom")

editor = replace_once(
    editor,
'''        view.font = MailTypography.baseFont\n        view.typingAttributes[.font] = MailTypography.baseFont\n''',
'''        view.font = displayFont(preserving: nil)\n        view.typingAttributes[.font] = displayFont(preserving: nil)\n''',
    "configure display font",
)

editor = replace_once(
    editor,
'''        textView.setRichText(attributed)\n        textView.typingAttributes[.font] = MailTypography.baseFont\n        lastPublishedPlain = pendingExternal.plain\n''',
'''        textView.setRichText(attributed)\n        applyDisplayZoom()\n        textView.typingAttributes[.font] = displayFont(preserving: textView.typingAttributes[.font] as? NSFont)\n        lastPublishedPlain = pendingExternal.plain\n''',
    "zoom externally loaded rich text",
)

old_wrap = '''    private func updateWrapWidth() {\n        guard let scrollView, let textView else { return }\n        scrollView.layoutSubtreeIfNeeded()\n\n        // NSClipView.bounds is expressed in document coordinates, so at 130%/150%\n        // zoom it already represents the exact width that is visibly available to\n        // the text. Using NSScrollView.contentSize here made the document wider than\n        // the visible editor and caused the delayed wrap/horizontal scrolling bug.\n        let visibleWidth = scrollView.contentView.bounds.width\n        let scale = max(CGFloat(1.0), scrollView.magnification)\n        let fallbackWidth = scrollView.contentSize.width / scale\n        let width = max(CGFloat(120), visibleWidth > 1 ? visibleWidth : fallbackWidth)\n\n        textView.isHorizontallyResizable = false\n        textView.autoresizingMask = [.width]\n        textView.minSize = NSSize(width: 0, height: 0)\n        textView.maxSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)\n        textView.textContainer?.widthTracksTextView = true\n        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)\n\n        if abs(textView.frame.width - width) > 0.5 || abs(lastWrapWidth - width) > 0.5 {\n            var frame = textView.frame\n            frame.size.width = width\n            frame.size.height = max(frame.size.height, scrollView.contentView.bounds.height)\n            textView.frame = frame\n            lastWrapWidth = width\n        }\n\n        normalizeParagraphWrapping()\n        if let container = textView.textContainer {\n            textView.layoutManager?.ensureLayout(for: container)\n        }\n\n        // There is intentionally no horizontal document range. Keep x pinned to\n        // zero as a final guard so the insertion caret always remains visible.\n        var origin = scrollView.contentView.bounds.origin\n        if origin.x != 0 {\n            origin.x = 0\n            scrollView.contentView.scroll(to: origin)\n            scrollView.reflectScrolledClipView(scrollView.contentView)\n        }\n    }\n'''
new_wrap = '''    private func updateWrapWidth() {\n        guard let scrollView, let textView else { return }\n        scrollView.layoutSubtreeIfNeeded()\n\n        // With scroll magnification disabled, documentVisibleRect is the actual\n        // editable width visible through the clip view. TextKit gets exactly that\n        // width, so the document cannot create a horizontal overflow range.\n        let visibleWidth = scrollView.documentVisibleRect.width\n        let fallbackWidth = scrollView.contentSize.width\n        let width = max(CGFloat(120), visibleWidth > 1 ? visibleWidth : fallbackWidth)\n\n        textView.isHorizontallyResizable = false\n        textView.autoresizingMask = [.width]\n        textView.minSize = NSSize(width: 0, height: 0)\n        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)\n\n        if abs(textView.frame.width - width) > 0.5 || abs(lastWrapWidth - width) > 0.5 {\n            var frame = textView.frame\n            frame.size.width = width\n            frame.size.height = max(frame.size.height, scrollView.documentVisibleRect.height)\n            textView.frame = frame\n            lastWrapWidth = width\n        }\n\n        if let container = textView.textContainer {\n            container.widthTracksTextView = true\n            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)\n            container.lineBreakMode = .byWordWrapping\n            textView.layoutManager?.ensureLayout(for: container)\n        }\n        normalizeParagraphWrapping()\n\n        var origin = scrollView.contentView.bounds.origin\n        if origin.x != 0 {\n            origin.x = 0\n            scrollView.contentView.scroll(to: origin)\n            scrollView.reflectScrolledClipView(scrollView.contentView)\n        }\n    }\n'''
editor = replace_once(editor, old_wrap, new_wrap, "replace magnified wrap-width logic")

# Any editor-created/reset font must use the current display zoom. Export still
# normalizes the attributed text to Calibri Light 10.5 pt before Outlook sees it.
editor = editor.replace("MailTypography.baseFont", "displayFont(preserving: nil)")

editor_path.write_text(editor, encoding="utf-8")

info["CFBundleShortVersionString"] = "1.65.0"
info["CFBundleVersion"] = "66"
info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=False))

contracts_path = repo / "tests" / "test_source_contracts.py"
contracts = contracts_path.read_text(encoding="utf-8")
contracts = contracts.replace('self.assertEqual(info["CFBundleShortVersionString"], "1.64.0")', 'self.assertEqual(info["CFBundleShortVersionString"], "1.65.0")')
contracts = contracts.replace('self.assertEqual(info["CFBundleVersion"], "65")', 'self.assertEqual(info["CFBundleVersion"], "66")')
contracts = contracts.replace('self.assertIn("MailTypography.baseFont", self.read("RichTextMailEditor.swift"))', 'self.assertIn("MailTypography.font(preserving:", self.read("RichTextMailEditor.swift"))')
contracts = contracts.replace('self.assertIn("scrollView.allowsMagnification = true", editor)', 'self.assertIn("scrollView.allowsMagnification = false", editor)')
contracts = contracts.replace('self.assertIn("scrollView.contentView.bounds.width", editor)', 'self.assertIn("scrollView.documentVisibleRect.width", editor)')
contracts = contracts.replace('self.assertIn("textView.maxSize = NSSize(width: width", editor)', 'self.assertIn("textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude", editor)')
needle = '''        self.assertIn("origin.x = 0", editor)\n'''
addition = '''        self.assertIn("origin.x = 0", editor)\n        self.assertIn("scrollView.magnification = 1.0", editor)\n        self.assertIn("private func displayFont(preserving source: NSFont?)", editor)\n        self.assertIn("private func applyDisplayZoom()", editor)\n        self.assertNotIn("zoomObservation", editor)\n        self.assertNotIn("scrollView.contentSize.width / scale", editor)\n'''
contracts = replace_once(contracts, needle, addition, "editor root-fix source contract")
contracts_path.write_text(contracts, encoding="utf-8")

verify_path = repo / "tests" / "verify_update.py"
verify = verify_path.read_text(encoding="utf-8")
verify = verify.replace("manifest['version'] == '1.64.0' and manifest['build'] == 65", "manifest['version'] == '1.65.0' and manifest['build'] == 66")
verify = verify.replace("manifest['download_url'] == 'Replyzen-update-1.64.zip'", "manifest['download_url'] == 'Replyzen-update-1.65.zip'")
verify = verify.replace("PASS: 1.64 version/build", "PASS: 1.65 version/build")
verify_path.write_text(verify, encoding="utf-8")

notes_de = "ReplyZen 1.65: Der Rich-Text-Editor verwendet für den sichtbaren Zoom keine NSScrollView-Vergrößerung mehr. Der Zoom wird jetzt ausschließlich über die Darstellung der Editor-Schrift umgesetzt, während die eigentliche TextKit-Fläche immer 1:1 auf die sichtbare Editorbreite begrenzt bleibt. Dadurch bricht Text direkt an der rechten Kante um und der Editor erzeugt beim Tippen, Einfügen, bei langen Wörtern oder URLs keinen horizontalen Dokumentbereich. Beim Einsetzen in Outlook bleibt die Schrift weiterhin Calibri Light 10,5 pt; die übrige Mail-Logik bleibt unverändert."
notes_en = "ReplyZen 1.65: The rich-text editor no longer uses NSScrollView magnification for its visible zoom. Zoom is now display-only through the editor font while the underlying TextKit document remains at 1:1 and is constrained to the visible editor width. Text therefore wraps at the right edge and typing, pasted content, long words and URLs no longer create a horizontal document range. Outlook output remains Calibri Light 10.5 pt and the rest of the mail flow is unchanged."
notes_es = "ReplyZen 1.65: El editor de texto enriquecido ya no usa la ampliación de NSScrollView para el zoom visible. El zoom ahora solo cambia la visualización de la fuente del editor, mientras que el documento TextKit permanece a escala 1:1 y limitado al ancho visible. Así el texto se ajusta en el borde derecho y escribir, pegar contenido, palabras largas o URL ya no crea un área horizontal. La salida a Outlook sigue siendo Calibri Light 10,5 pt y el resto del flujo de correo no cambia."
(root / "Release-notes.txt").write_text(notes_de + "\n", encoding="utf-8")
(root / "Release-notes.localized.json").write_text(json.dumps({"de": notes_de, "en-US": notes_en, "es": notes_es}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

print("Migrated ReplyZen to 1.65.0 / build 66")
