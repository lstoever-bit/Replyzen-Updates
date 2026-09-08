#!/usr/bin/env python3
"""One-time checked migration for ReplyZen 1.54 first-visible layout stability."""
from pathlib import Path
import plistlib
import sys

root = Path(sys.argv[1])
app = root / "app"
info_path = app / "Info.plist"
info = plistlib.loads(info_path.read_bytes())

if info["CFBundleShortVersionString"] == "1.54.0":
    print("ReplyZen 1.54 migration already applied")
    raise SystemExit(0)
if info["CFBundleShortVersionString"] != "1.53.0":
    raise SystemExit("Unexpected source version; refusing to modify newer work")


def once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise RuntimeError("Expected one source marker: " + old[:140])
    return text.replace(old, new, 1)


# 1) Make the first visible window pass deterministic. Activating ReplyZen before
# makeKeyAndOrderFront prevents the hosting hierarchy from being laid out once as
# an inactive accessory panel and only correcting itself after the next app switch.
panel_path = app / "FloatingPanelController.swift"
panel = panel_path.read_text(encoding="utf-8")
panel = once(
    panel,
    """        resizeForCurrentState(animated: false, centered: true)
        panel.orderFrontRegardless()
        if activate {
            panel.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func selectInstructionTextSoon() {
""",
    """        resizeForCurrentState(animated: false, centered: true)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        stabilizeVisibleContent()
    }

    /// SwiftUI contains an AppKit-backed rich-text editor. On a freshly shown
    /// accessory panel AppKit can finish the native subview layout one run-loop
    /// later than SwiftUI. Run a few cheap, bounded layout/display passes while
    /// the window is visible so the complete workspace is correct immediately.
    private func stabilizeVisibleContent() {
        for delay: TimeInterval in [0.0, 0.035, 0.11] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.panel.isVisible else { return }
                let roots = [self.panel.contentViewController?.view, self.panel.contentView].compactMap { $0 }
                for root in roots {
                    root.needsLayout = true
                    root.layoutSubtreeIfNeeded()
                    root.needsDisplay = true
                    root.displayIfNeeded()
                }
                self.panel.invalidateShadow()
            }
        }
    }

    func selectInstructionTextSoon() {
"""
)
panel_path.write_text(panel, encoding="utf-8")


# 2) Keep the third-party AppKit scroll view inside the SwiftUI editor slot.
# This prevents the native view from temporarily painting over the header/mode row
# before its first proper SwiftUI layout pass.
editor_path = app / "RichTextMailEditor.swift"
editor = editor_path.read_text(encoding="utf-8")
editor = once(
    editor,
    """            scrollView.identifier = NSUserInterfaceItemIdentifier("replyzen.mailEditor")
            scrollView.hasVerticalScroller = true
            scrollView.drawsBackground = false
            scrollView.allowsMagnification = true
""",
    """            scrollView.identifier = NSUserInterfaceItemIdentifier("replyzen.mailEditor")
            scrollView.hasVerticalScroller = true
            scrollView.drawsBackground = false
            scrollView.wantsLayer = true
            scrollView.layer?.masksToBounds = true
            scrollView.contentView.wantsLayer = true
            scrollView.contentView.layer?.masksToBounds = true
            scrollView.allowsMagnification = true
"""
)
editor = once(
    editor,
    """            scrollView.maxMagnification = 1.8
            scrollView.magnification = 1.30
        }
""",
    """            scrollView.maxMagnification = 1.8
            scrollView.magnification = 1.30
            scrollView.needsLayout = true
            scrollView.layoutSubtreeIfNeeded()
        }
"""
)
editor = once(
    editor,
    """            ReplyZenRichEditorSurface(context: adapter.context, adapter: adapter)
                .frame(minHeight: height == nil ? 80 : nil, maxHeight: .infinity)
""",
    """            ReplyZenRichEditorSurface(context: adapter.context, adapter: adapter)
                .frame(minHeight: height == nil ? 180 : nil, idealHeight: height == nil ? 340 : nil, maxHeight: .infinity)
                .clipped()
"""
)
editor = once(
    editor,
    """        .frame(height: height)
        .frame(maxHeight: height == nil ? .infinity : nil)
        .modifier(WorkspaceCard())
""",
    """        .frame(height: height)
        .frame(maxHeight: height == nil ? .infinity : nil)
        .layoutPriority(height == nil ? 1 : 0)
        .modifier(WorkspaceCard())
"""
)
editor_path.write_text(editor, encoding="utf-8")


# 3) Mark non-editor controls as non-compressible vertically. The editor is the
# flexible area; header, mode controls, options and reminder must always remain visible.
workspace_path = app / "WorkspaceComponents.swift"
workspace = workspace_path.read_text(encoding="utf-8")
workspace = once(
    workspace,
    """        .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 14)
        .accessibilityElement(children: .contain)
""",
    """        .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 14)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
"""
)
workspace_path.write_text(workspace, encoding="utf-8")

mail_path = app / "MailWorkspaceView.swift"
mail = mail_path.read_text(encoding="utf-8")
mail = once(
    mail,
    """                    modeRow
                    VStack(alignment: .leading, spacing: 8) {
""",
    """                    modeRow
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 8) {
"""
)
mail = once(
    mail,
    """                    optionsRow
                    reminderControl
""",
    """                    optionsRow
                        .fixedSize(horizontal: false, vertical: true)
                    reminderControl
                        .fixedSize(horizontal: false, vertical: true)
"""
)
mail_path.write_text(mail, encoding="utf-8")


# Version/build.
info["CFBundleShortVersionString"] = "1.54.0"
info["CFBundleVersion"] = "55"
info_path.write_bytes(plistlib.dumps(info, sort_keys=False))

# Keep source/build contracts aligned before the test phase.
contracts = root.parent / "tests" / "test_source_contracts.py"
text = contracts.read_text(encoding="utf-8")
text = text.replace("'1.53.0'", "'1.54.0'").replace("'54'", "'55'", 1)
needle = "        self.assertIn('resizeForCurrentState(animated: false, centered: true)', panel)\n"
addition = needle + "        self.assertIn('panel.makeKeyAndOrderFront(nil)', panel)\n        self.assertIn('private func stabilizeVisibleContent()', panel)\n"
if needle not in text:
    raise RuntimeError("Could not update window source contract")
text = text.replace(needle, addition, 1)
needle = "        self.assertIn('NSTextStorage.didProcessEditingNotification', editor)\n"
addition = needle + "        self.assertIn('.clipped()', editor)\n        self.assertIn('layer?.masksToBounds = true', editor)\n        self.assertIn('idealHeight: height == nil ? 340', editor)\n"
if needle not in text:
    raise RuntimeError("Could not update editor source contract")
text = text.replace(needle, addition, 1)
contracts.write_text(text, encoding="utf-8")

verify = root.parent / "tests" / "verify_update.py"
text = verify.read_text(encoding="utf-8")
text = text.replace("'1.53.0' and manifest['build'] == 54", "'1.54.0' and manifest['build'] == 55")
text = text.replace("'Replyzen-update-1.53.zip'", "'Replyzen-update-1.54.zip'")
text = text.replace("PASS: 1.53 version/build", "PASS: 1.54 version/build")
verify.write_text(text, encoding="utf-8")

print("Migrated ReplyZen to 1.54.0 / build 55 with first-visible layout stabilization")
