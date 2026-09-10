#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(sys.argv[1])
delegate = (root / "app" / "AppDelegate.swift").read_text(encoding="utf-8")
start = delegate.index("    private func closePanel() {")
end = delegate.index("    private func showError", start)
block = delegate[start:end]
assert "restoreOutlookOverlayAfterPanelClose()" in block
assert "outlook.activateOutlook(pid: pid)" in block
assert "DispatchQueue.main.asyncAfter(deadline: .now() + 0.08)" in block
assert "toolbarButton.setSuppressed(false)" in block
assert block.index("outlook.activateOutlook(pid: pid)") < block.index("toolbarButton.setSuppressed(false)")
print("PASS: closing ReplyZen reactivates Outlook before restoring the action overlay")
