#!/usr/bin/env python3
"""Verify the exact archive and manifest consumed by the existing updater."""
import hashlib
import json
from pathlib import Path
import plistlib
import sys
import zipfile

root = Path(sys.argv[1])
manifest = json.loads((root / 'update.json').read_text())
assert manifest['version'] == '1.48.0' and manifest['build'] == 49
assert manifest['download_url'] == 'Replyzen-update-1.48.zip'
archive = root / manifest['download_url']
assert hashlib.sha256(archive.read_bytes()).hexdigest() == manifest['sha256']
with zipfile.ZipFile(archive) as package:
    assert package.testzip() is None
    info = plistlib.loads(package.read('Replyzen.app/Contents/Info.plist'))
    assert info['CFBundleIdentifier'] == 'com.lstoever.replyzen'
    assert info['CFBundleShortVersionString'] == manifest['version']
    assert int(info['CFBundleVersion']) == manifest['build']
    assert info['CFBundleDisplayName'] == 'ReplyZen'
    translations = json.loads(package.read('Replyzen.app/Contents/Resources/Localization.json'))
    assert len(translations) >= 250
    assert all(set(row) == {'de', 'en-US', 'es'} for row in translations.values())
    assert set(manifest['notes_localized']) == {'de', 'en-US', 'es'}
    binary = package.read('Replyzen.app/Contents/MacOS/Replyzen')
    assert binary[:4] == b'\xcf\xfa\xed\xfe'
    assert package.read('Replyzen.app/Contents/Resources/ReplyzenLogo.png')[:8] == b'\x89PNG\r\n\x1a\n'
    assert package.read('Replyzen.app/Contents/Resources/Replyzen.icns')[:4] == b'icns'
print('PASS: 1.48 version/build, bundle identity, archive, SHA-256, binary and icons')
