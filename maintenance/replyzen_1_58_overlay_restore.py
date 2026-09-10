#!/usr/bin/env python3
"""ReplyZen 1.58: restore the Outlook action overlay immediately after closing ReplyZen."""
from pathlib import Path
import plistlib
import sys

root = Path(sys.argv[1])
app = root / "app"
info_path = app / "Info.plist"
info = plistlib.loads(info_path.read_bytes())

if info.get("CFBundleShortVersionString") == "1.58.0":
    delegate = (app / "AppDelegate.swift").read_text(encoding="utf-8")
    assert "restoreOutlookOverlayAfterPanelClose" in delegate
    print("ReplyZen 1.58 overlay restore migration already applied")
    raise SystemExit(0)

if info.get("CFBundleShortVersionString") != "1.57.0" or str(info.get("CFBundleVersion")) != "58":
    raise SystemExit("Unexpected ReplyZen source version; refusing to modify")


def replace_once(text: str, before: str, after: str) -> str:
    count = text.count(before)
    if count != 1:
        raise RuntimeError(f"Expected exactly one source marker, found {count}: {before[:120]!r}")
    return text.replace(before, after, 1)

path = app / "AppDelegate.swift"
text = path.read_text(encoding="utf-8")
old = '''    private func closePanel() {
        isRunningFlow = false
        state.stage = .idle
        panel.hide()
        toolbarButton.setSuppressed(false)
    }
'''
new = '''    private func closePanel() {
        isRunningFlow = false
        state.stage = .idle
        panel.hide()
        restoreOutlookOverlayAfterPanelClose()
    }

    private func restoreOutlookOverlayAfterPanelClose() {
        // The ReplyZen workspace is an accessory app panel. While it is open,
        // ReplyZen itself becomes macOS' frontmost app and the Outlook action
        // palette is intentionally suppressed. If we simply unsuppress here,
        // the palette still sees Outlook as inactive and remains hidden until the
        // user clicks Outlook manually. Reactivate Outlook first, then unsuppress
        // on the next run-loop turn so the palette refreshes immediately.
        guard isOutlookRunning else {
            toolbarButton.setSuppressed(false)
            return
        }

        if let pid = outlook.runningPID() {
            outlook.activateOutlook(pid: pid)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.toolbarButton.setSuppressed(false)
        }
    }
'''
text = replace_once(text, old, new)
path.write_text(text, encoding="utf-8")

info["CFBundleShortVersionString"] = "1.58.0"
info["CFBundleVersion"] = "59"
info_path.write_bytes(plistlib.dumps(info, sort_keys=False))

notes = {
    "de": "ReplyZen 1.58: Wenn das große ReplyZen-Fenster geschlossen wird, aktiviert ReplyZen Outlook jetzt automatisch wieder und blendet das kleine Outlook-Aktionsmenü sofort erneut ein. Ein zusätzlicher Klick in Outlook ist nicht mehr nötig. Die gespeicherte Position des Outlook-Aktionsmenüs bleibt erhalten.",
    "en-US": "ReplyZen 1.58: Closing the main ReplyZen window now automatically reactivates Outlook and immediately restores the small Outlook action palette. No extra click in Outlook is required. The saved position of the Outlook action palette remains unchanged.",
    "es": "ReplyZen 1.58: Al cerrar la ventana principal de ReplyZen, Outlook se reactiva automáticamente y la pequeña paleta de acciones de Outlook vuelve a aparecer de inmediato. Ya no hace falta hacer clic de nuevo en Outlook. La posición guardada de la paleta se mantiene."
}
import json
(root / "Release-notes.localized.json").write_text(json.dumps(notes, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
(root / "Release-notes.txt").write_text(notes["de"] + "\n", encoding="utf-8")
print("Migrated ReplyZen to 1.58.0 / build 59: Outlook overlay restores after panel close")
