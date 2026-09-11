#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(sys.argv[1])
path = root.parent / "tests" / "test_source_contracts.py"
text = path.read_text(encoding="utf-8")
text = text.replace('self.assertIn("Picker(L10n.tr("Tag"), selection: $state.reminderDay)", workspace)', 'self.assertIn(\'Picker(L10n.tr("Tag"), selection: $state.reminderDay)\', workspace)')
text = text.replace('self.assertIn("Picker(L10n.tr("Uhrzeit"), selection: $state.reminderTime)", workspace)', 'self.assertIn(\'Picker(L10n.tr("Uhrzeit"), selection: $state.reminderTime)\', workspace)')
path.write_text(text, encoding="utf-8")
print("Normalized ReplyZen 1.62 reminder source-contract quoting")
