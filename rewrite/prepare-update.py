#!/usr/bin/env python3
"""Package the native core for an EXISTING locally signed ReplyZen installation.
No standalone-install workaround; no changes to UpdateManager's trust checks.
"""
from pathlib import Path
import json
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
VERSION = '2.0.0'
BUILD = 200
SOURCE = ROOT / 'source-current' / 'app'
subprocess.run([sys.executable, str(ROOT / 'rewrite/assemble.py')], check=True)
APP = ROOT / '.native-build/app'
s = (APP / 'AppDelegate.swift').read_text()
baseline = (SOURCE / 'AppDelegate.swift').read_text()

def once(old, new):
    global s
    if s.count(old) != 1:
        raise RuntimeError('Unexpected native assembly; refusing best-effort patch: ' + old[:80])
    s = s.replace(old, new, 1)

once('        // Preview: no automatic production updater.\n', '        configureUpdates()\n')
once('        // Preview: do not register a second login item.\n', '        _ = loginItem.enableAtLoginIfPossible()\n')
a = baseline.index('        let updates = NSMenuItem(')
b = baseline.index('        let quit = NSMenuItem(', a)
anchor = '        let quit = NSMenuItem('
once(anchor, baseline[a:b] + anchor)
(APP / 'AppDelegate.swift').write_text(s)
info_file = APP / 'Info.plist'
info = plistlib.loads(info_file.read_bytes())
info.update(CFBundleIdentifier='com.lstoever.replyzen', CFBundleDisplayName='ReplyZen',
            CFBundleName='Replyzen', CFBundleShortVersionString=VERSION,
            CFBundleVersion=str(BUILD))
info_file.write_bytes(plistlib.dumps(info, sort_keys=False))
notes = {
    'de': 'ReplyZen 2.0: Neuer Mail-Kern f\u00fcr klassisches Outlook f\u00fcr Mac. Antworten, Allen antworten, Weiterleiten und Neue Mail werden direkt als Outlook-Entw\u00fcrfe erstellt, ohne simulierte Klicks oder Einf\u00fcgen per Tastatur. Beim ersten Zugriff die macOS-Frage zur Steuerung von Microsoft Outlook erlauben. Installation \u00fcber den bisherigen In-App-Updater und die lokale ReplyZen-Signatur. Kein automatischer Versand. Neue native Fassung: Build, Kern- und Schnittstellentests bestanden; noch kein vollst\u00e4ndiger Test mit dem angemeldeten Nutzerpostfach. Nicht f\u00fcr New Outlook ohne AppleScript-Unterst\u00fctzung.',
    'en-US': 'ReplyZen 2.0: New native draft engine for classic Outlook for Mac. Reply, Reply All, Forward and New Mail use Outlook draft objects instead of simulated clicks or paste shortcuts. Allow macOS Automation access to Microsoft Outlook on first use. Uses the existing in-app updater and local ReplyZen signing identity. Never sends automatically. Native build, core and bridge tests passed; authenticated user-mailbox validation is still outstanding. Not for New Outlook without AppleScript support.',
    'es': 'ReplyZen 2.0: Nuevo motor de borradores para Outlook cl\u00e1sico para Mac, sin clics ni pegado simulado. Permite el acceso de Automatizaci\u00f3n a Microsoft Outlook al primer uso. Usa el actualizador integrado y la firma local de ReplyZen. No env\u00eda correos autom\u00e1ticamente. Compilaci\u00f3n y pruebas del motor correctas; falta validar el buz\u00f3n autenticado del usuario. No compatible con New Outlook sin AppleScript.'
}
(ROOT / '.native-build/Release-notes.txt').write_text(notes['de'] + '\n')
(ROOT / '.native-build/Release-notes.localized.json').write_text(json.dumps(notes, ensure_ascii=False, indent=2) + '\n')
for name in ['UpdateManager.swift', 'KeychainStore.swift', 'AppState.swift', 'LoginItemManager.swift',
             'OpenAIClient.swift', 'NewMailSubject.swift', 'MailTypography.swift', 'CalendarManager.swift']:
    if (APP / name).read_bytes() != (SOURCE / name).read_bytes():
        raise RuntimeError('Unexpected change to preserved module: ' + name)
assert 'configureUpdates()' in s and 'Nach Updates suchen' in s
assert 'com.lstoever.replyzen.nativepreview' not in info_file.read_text()
assert info['NSAppleEventsUsageDescription']
assert (SOURCE / 'AppDelegate.swift').read_text() == baseline
print(f'Prepared {VERSION} / {BUILD} for existing in-app updater; local signing checks unchanged')
