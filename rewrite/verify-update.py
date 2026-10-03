#!/usr/bin/env python3
"""Validate the exact package consumed by the already-installed updater."""
from pathlib import Path
import hashlib
import json
import plistlib
import sys
import zipfile

ROOT = Path(__file__).resolve().parent.parent
root = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / '.native-build'
manifest = json.loads((root / 'update.json').read_text())
assert manifest['version'] == '2.0.0' and manifest['build'] == 200
assert manifest['download_url'] == 'Replyzen-update-2.0.zip'
assert manifest['build'] > json.loads((ROOT / 'update.json').read_text())['build'] or json.loads((ROOT / 'update.json').read_text()) == manifest
archive = root / manifest['download_url']
assert hashlib.sha256(archive.read_bytes()).hexdigest() == manifest['sha256']
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
    assert all(not name.startswith('/') and '..' not in Path(name).parts for name in z.namelist())
    info = plistlib.loads(z.read('Replyzen.app/Contents/Info.plist'))
    assert info['CFBundleIdentifier'] == 'com.lstoever.replyzen'
    assert info['CFBundleShortVersionString'] == manifest['version']
    assert int(info['CFBundleVersion']) == manifest['build']
    assert info['CFBundleDisplayName'] == 'ReplyZen'
    assert info['NSAppleEventsUsageDescription']
    script = z.read('Replyzen.app/Contents/Resources/Outlook.applescript')
    assert script == (ROOT / 'rewrite/Scripts/Outlook.applescript').read_bytes()
    assert not any(line.strip().startswith(b'send ') for line in script.splitlines())
    assert z.read('Replyzen.app/Contents/MacOS/Replyzen')[:4] == b'\xcf\xfa\xed\xfe'
    assert z.read('Replyzen.app/Contents/Resources/Replyzen.icns')[:4] == b'icns'
    assert set(manifest['notes_localized']) == {'de', 'en-US', 'es'}
app = root / 'app'
for name in ['UpdateManager.swift', 'KeychainStore.swift', 'AppState.swift', 'LoginItemManager.swift']:
    assert (app / name).read_bytes() == (ROOT / 'source-current/app' / name).read_bytes()
s = (app / 'AppDelegate.swift').read_text()
assert s.count('        configureUpdates()') == 1
assert s.count('        let updates = NSMenuItem(') == 1
assert s.count('        let source = NSMenuItem(title: L10n.tr("Update-Quelle') == 1
assert '        _ = loginItem.enableAtLoginIfPossible()' in s
assert 'NativeMailTransaction' in s and 'OutlookReplyInsertion' not in s
for removed in ['OutlookReplyInsertion', 'ReplyInsertionPolicy', 'ReplyWindowTracker', 'ReplyForegroundGuard', 'ReplyRecoveryRules', 'ReplyEditorSupport']:
    assert not (app / (removed + '.swift')).exists()
assert 'localSigningIdentity = "Replyzen Local Signing"' in (app / 'UpdateManager.swift').read_text()
print('PASS: exact 2.0 updater archive, SHA-256, app identity, native script, preserved updater/settings/keychain, restored update menu')
