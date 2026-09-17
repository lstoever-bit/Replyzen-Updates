#!/usr/bin/env python3
from pathlib import Path
import json
import sys

root = Path(sys.argv[1])
path = root / "app" / "Resources" / "Localization.json"
catalog = json.loads(path.read_text(encoding="utf-8"))
key = "Outlook hat den Forward-Editor nicht geöffnet. Der Text wurde in die Zwischenablage kopiert."
catalog[key] = {
    "de": key,
    "en-US": "Outlook did not open the Forward editor. The text was copied to the clipboard.",
    "es": "Outlook no abrió el editor de reenvío. El texto se copió al portapapeles."
}
path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print("ReplyZen 1.66 Forward localization present")
