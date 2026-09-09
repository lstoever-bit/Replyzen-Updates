#!/usr/bin/env python3
from pathlib import Path
import json
import sys

root = Path(sys.argv[1])
app = root / "app"

# Reuse the already-localized zoom help key exactly.
toolbar = app / "EditorToolbar.swift"
text = toolbar.read_text(encoding="utf-8")
text = text.replace(
    "Editor-Zoom. Outlook erhält unverändert Calibri Light, 10,5 pt.",
    "Editor-Zoom. Outlook erhält unverändert Calibri Light 10,5 pt."
)
toolbar.write_text(text, encoding="utf-8")

# Localize the one new subject-commit failure message introduced in 1.56.
catalog_path = app / "Resources" / "Localization.json"
catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
key = "Der Betreff konnte nicht zuverlässig in Outlook eingesetzt werden. Der Mailtext liegt in der Zwischenablage."
catalog[key] = {
    "en-US": "The subject could not be inserted reliably in Outlook. The email body is in the clipboard.",
    "de": key,
    "es": "El asunto no se pudo insertar de forma fiable en Outlook. El texto del correo está en el portapapeles."
}
catalog_path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

print("Applied ReplyZen 1.56 localization fixes")
