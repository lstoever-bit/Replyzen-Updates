#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(sys.argv[1])
delegate = (root / "app" / "AppDelegate.swift").read_text(encoding="utf-8")
start = delegate.index("    private func closePanel() {")
end = delegate.index("    private func showError", start)
block = delegate[start:end]
assert "restoreOutlookOverlayAfterPanelClose()" in block
helper = block[block.index("    private func restoreOutlookOverlayAfterPanelClose() {"):]
assert "guard isOutlookRunning else" in helper
normal = helper[helper.index("if let pid = outlook.runningPID()") :]
activate = normal.index("outlook.activateOutlook(pid: pid)")
delayed = normal.index("DispatchQueue.main.asyncAfter(deadline: .now() + 0.08)")
unsuppress = normal.index("self?.toolbarButton.setSuppressed(false)")
assert activate < delayed < unsuppress
print("PASS: closing ReplyZen reactivates Outlook before restoring the action overlay")
