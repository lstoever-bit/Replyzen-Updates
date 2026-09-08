#!/usr/bin/env python3
import json
from pathlib import Path
import re
import sys
root=Path(sys.argv[1])
catalog=json.loads((root/'app/Resources/Localization.json').read_text())
assert len(catalog)>=250
for key,row in catalog.items():
    assert set(row)=={'en-US','de','es'},key
    expected=sorted(re.findall(r'\{\d+\}',key))
    for lang,value in row.items():
        assert value and sorted(re.findall(r'\{\d+\}',value))==expected,(key,lang)
for path in (root/'app').glob('*.swift'):
    if path.name=='LocalizationCore.swift':continue
    for match in re.finditer(r'L10n\.(?:tr|source)\(("(?:\\.|[^"\\])*")',path.read_text()):
        key=json.loads(match[1])
        assert key in catalog,(path.name,key)
# UI text must either use the catalog or be an intentional brand/code/autonym.
allowed={'ReplyZen','IBAN','BIC','EUR','DE','EN','Google Calendar · lennard@minubo.com','sk-…',''}
remaining=[]
for name in ['OverlayView.swift','MailWorkspaceView.swift','WorkspaceComponents.swift','EditorToolbar.swift']:
    text=(root/'app'/name).read_text()
    for match in re.finditer(r'(?:Text|Button|TextField|SecureField|Toggle|Picker|Label)\("([^"\\]*)"',text):
        if match[1] not in allowed: remaining.append((name,match[1]))
assert not remaining,remaining
assert 'NSMenuItem(title: L10n.tr("Einstellungen…")' in (root/'app/AppDelegate.swift').read_text()
assert 'refreshLocalization()' in (root/'app/OutlookToolbarButtonController.swift').read_text()
print(f'PASS: {len(catalog)} complete translation keys; placeholders; all localization calls; raw UI-label audit')
