#!/usr/bin/env python3
"""One-time 1.46 -> 1.47 localization migration with audited source keys.
Produces canonical Swift source and a complete three-language resource catalog.
Never rewrites identifiers, API prompts, accessibility matching, or user data.
"""
from pathlib import Path
import json
import plistlib
import re
import sys

ROOT = Path(sys.argv[1])
APP = ROOT / 'app'
REPO = ROOT.parent
info = plistlib.loads((APP / 'Info.plist').read_bytes())
if info['CFBundleShortVersionString'] == '1.47.0':
    assert (APP / 'Resources/Localization.json').is_file()
    print('Localization migration already applied')
    raise SystemExit(0)
if info['CFBundleShortVersionString'] != '1.46.0':
    raise SystemExit('Unexpected baseline; will not overwrite another version')

catalog = {}
for table in sorted((REPO / 'maintenance/localization').glob('*.txt')):
    for row in table.read_text().splitlines():
        if not row or row.startswith('#'): continue
        columns = row.split('|')
        if len(columns) not in (3,4): raise ValueError('Invalid translation row: '+row)
        key, english, spanish = columns[:3]
        german = columns[3] if len(columns) == 4 else key.replace('Replyzen ', 'ReplyZen ').replace('Replyzen.', 'ReplyZen.')
        entry = {'en-US': english, 'de': german, 'es': spanish}
        if key in catalog and catalog[key] != entry: raise ValueError('Conflicting key: '+key)
        expected = sorted(re.findall(r'\{\d+\}', key))
        for language, text in entry.items():
            if not text or sorted(re.findall(r'\{\d+\}', text)) != expected:
                raise ValueError('Invalid placeholders: '+key+' '+language)
        catalog[key] = entry
assert len(catalog) >= 250, len(catalog)

# Small Swift lexer: comments, multiline strings and raw regex strings are skipped.
# Normal string interpolations retain their complete original Swift expressions.
def skip_comment(s, i):
    if s.startswith('//', i):
        end = s.find('\n', i)
        return len(s) if end < 0 else end
    if s.startswith('/*', i):
        depth, j = 1, i+2
        while depth and j < len(s):
            if s.startswith('/*', j): depth += 1; j += 2
            elif s.startswith('*/', j): depth -= 1; j += 2
            else: j += 1
        return j
    return None

def read_string(s, i):
    j, parts, arguments = i+1, [], []
    escapes = {'n':'\n','r':'\r','t':'\t','0':'\0','"':'"',"'":"'",'\\':'\\'}
    while j < len(s):
        c = s[j]
        if c == '"': return j+1, ''.join(parts), arguments
        if c != '\\': parts.append(c); j += 1; continue
        if s[j+1] == '(':
            begin, k, depth = j+2, j+2, 1
            while depth:
                if k >= len(s): raise ValueError('Unterminated interpolation')
                comment = skip_comment(s, k)
                if comment is not None: k = comment; continue
                if s[k] == '"': k = read_string(s, k)[0]; continue
                if s[k] == '(': depth += 1
                elif s[k] == ')': depth -= 1
                k += 1
            parts.append('{'+str(len(arguments))+'}')
            arguments.append(s[begin:k-1])
            j = k
        elif s.startswith('\\u{',j):
            end = s.index('}',j+3)
            parts.append(chr(int(s[j+3:end],16))); j=end+1
        else:
            parts.append(escapes.get(s[j+1], '\\'+s[j+1])); j += 2
    raise ValueError('Unterminated string')

def literals(s):
    i = 0
    while i < len(s):
        comment = skip_comment(s, i)
        if comment is not None: i=comment; continue
        raw = re.match(r'(#+)("""|")',s[i:]) if s[i] == '#' else None
        if raw:
            end = s.find(raw[2]+raw[1],i+len(raw[0]))
            if end < 0: raise ValueError('Unterminated raw string')
            i=end+len(raw[2]+raw[1]); continue
        if s.startswith('"""',i):
            end=s.find('"""',i+3)
            if end < 0: raise ValueError('Unterminated multiline string')
            i=end+3; continue
        if s[i]=='"':
            end,key,args=read_string(s,i)
            yield i,end,key,args
            i=end
        else: i += 1

def once(text, old, new):
    if text.count(old) != 1: raise ValueError('Expected one marker: '+old[:110])
    return text.replace(old,new,1)

def before(text, marker, addition):
    return once(text, marker, addition+marker)

sources = {p.name: p.read_text() for p in APP.glob('*.swift')}
changed = dict(sources)

# Convert concatenated diagnostic prefixes to explicit value-preserving templates.
s = changed['AppDelegate.swift']
s = once(s, '''sourceStatus = (wasAutoSaved ? "PDF automatisch aus Outlook gespeichert und direkt mit OpenAI gelesen: " : "PDF direkt mit OpenAI gelesen: ")
                        + selectedPDFs.map(\\.lastPathComponent).joined(separator: ", ")''', '''sourceStatus = L10n.source(wasAutoSaved ? "PDF automatisch aus Outlook gespeichert und direkt mit OpenAI gelesen: {0}" : "PDF direkt mit OpenAI gelesen: {0}", selectedPDFs.map(\\.lastPathComponent).joined(separator: ", "))''')
s = once(s, 'sourceStatus = "Kein direkt zugängliches PDF; lokal gelesen: " + fallback.usedFiles.joined(separator: ", ")', 'sourceStatus = L10n.source("Kein direkt zugängliches PDF; lokal gelesen: {0}", fallback.usedFiles.joined(separator: ", "))')
changed['AppDelegate.swift'] = s

ui = {'OverlayView.swift','WorkspaceComponents.swift','MailWorkspaceView.swift','EditorToolbar.swift'}
skip = {'LocalizationCore.swift','AppLocalization.swift','MailTypography.swift','MailFontResolver.swift','CommandStore.swift'}
counts = {}
for name, s in list(changed.items()):
    if name in skip: continue
    edits=[]
    for start,end,key,args in literals(s):
        if key not in catalog: continue
        prefix=s[max(0,start-90):start]
        if prefix.rstrip().endswith(('L10n.tr(', 'L10n.source(')): continue
        line=s[s.rfind('\n',0,start)+1:s.find('\n',end) if s.find('\n',end)>=0 else len(s)]
        # AppState enum display names and ReplyTone names are presentation only.
        presentation = name in ui or name == 'ReplyCommand.swift' or (name == 'AppState.swift' and 'return ' in line)
        if name == 'AppDelegate.swift':
            presentation = any(x in line for x in ['NSMenuItem(title:', '.addButton(withTitle:', '.messageText =', '.informativeText =', '.title =', '.prompt ='])
            a=s.find('private func copyPaymentDetails()')
            b=s.find('private func createCalendarEvent()',a)
            if a<=start<b: presentation=True
        # Canonical status values must not change locale-sensitive control logic.
        fn='tr' if presentation else 'source'
        values=[]
        for expr in args:
            if expr.strip() == 'message' and name in {'CalendarManager.swift','UpdateManager.swift'}:
                values.append('L10n.diagnostic(message)')
            elif 'formatter.string(from: self.state.calendarStart)' == expr.strip():
                values.append('L10n.DateValue(self.state.calendarStart, timeZone: CalendarManager.eventTimeZone)')
            else: values.append(expr)
        # The two manually migrated sourceStatus expressions already contain keys.
        if '{0}' in key and not args and name == 'AppDelegate.swift' and 'sourceStatus = L10n.source' in line: continue
        replacement='L10n.'+fn+'('+json.dumps(key,ensure_ascii=False)
        if values: replacement += ', '+', '.join(values)
        replacement += ')'
        edits.append((start,end,replacement))
    for start,end,replacement in reversed(edits): s=s[:start]+replacement+s[end:]
    if name in ui:
        # Observe the shared preference without recreating views or discarding drafts.
        s=re.sub(r'(struct \w+: View \{\n)',r'\1    @ObservedObject private var appLocalization = AppLocalization.shared\n',s)
    changed[name]=s
    counts[name]=len(edits)
assert sum(counts.values()) >= 250, counts

# Display String-backed model diagnostics at the boundary, not inside the model.
s=changed['OverlayView.swift']
for field in ['statusText','startupJoke','paymentWarning','paymentSourceStatus','calendarWarning','calendarListStatus','errorMessage']:
    s=s.replace('Text(state.'+field+')','Text(L10n.render(state.'+field+'))')
s=s.replace(': state.googleOAuthStatus)', ': L10n.render(state.googleOAuthStatus))')
s=s.replace('? state.successMessage', '? L10n.render(state.successMessage)')
s=once(s, '.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))', '.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))\n        .environment(\\.locale, appLocalization.locale)')
changed['OverlayView.swift']=s
s=changed['MailWorkspaceView.swift']
s=s.replace('if case .unavailable(let message) = state.mailStatus { return message }', 'if case .unavailable(let message) = state.mailStatus { return L10n.render(message) }')
# Day labels are a computed presentation value, not a static array frozen at startup.
s=s.replace('private static let days: [(label: String, code: String)] = [','private static var days: [(label: String, code: String)] { [')
s=once(s, '    ]\n    private static let times', '    ] }\n    private static let times')
changed['MailWorkspaceView.swift']=s
s=changed['WorkspaceComponents.swift']
s=once(s, '                    Text("ReplyZen").font(.headline)', '                    Text("ReplyZen").font(.headline)\n                    InterfaceLanguagePicker()\n                    Divider()')
s=s.replace('.padding(20).frame(width: 300)', '.padding(20).frame(width: 360)')
changed['WorkspaceComponents.swift']=s

# Native AppKit menu labels and independent Settings window also update immediately.
s=changed['AppDelegate.swift']
s=once(s, 'import AppKit\n', 'import AppKit\nimport SwiftUI\n')
s=before(s,'    private var statusItem: NSStatusItem?', '''    private var languageObserver: NSObjectProtocol?
    private var languageSettingsWindow: NSWindow?

''')
s=before(s, '        configureStateActions()\n', '''        _ = AppLocalization.shared
        languageObserver = NotificationCenter.default.addObserver(
            forName: .replyZenLanguageDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshInterfaceLanguage() }
''')
s=before(s, '        toolbarButton.stop()\n    }\n\n    func applicationShouldSaveSecureApplicationState', '''        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
''')
s=before(s,'        let login = NSMenuItem', '''        let settings = NSMenuItem(title: L10n.tr("Einstellungen…"), action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

''')
s=before(s,'    @objc private func menuReply()', '''    @objc private func menuSettings() {
        if languageSettingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 250),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: InterfaceSettingsView())
            window.center()
            languageSettingsWindow = window
        }
        languageSettingsWindow?.title = L10n.tr("Einstellungen")
        languageSettingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshInterfaceLanguage() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            configureStatusItem()
            if let update = availableUpdate {
                updateMenuItem?.title = L10n.tr("Update verfügbar: {0}…", update.manifest.version)
            }
        }
        toolbarButton.refreshLocalization()
        languageSettingsWindow?.title = L10n.tr("Einstellungen")
        state.objectWillChange.send()
    }

''')
s=once(s,'alert.messageText = title == "Replyzen" ? "Replyzen" : "Replyzen · \\(title)"', 'alert.messageText = title == "Replyzen" ? ReplyZenBrand.displayName : ReplyZenBrand.displayName + " · " + L10n.render(title)')
s=once(s,'        alert.informativeText = message\n','        alert.informativeText = L10n.render(message)\n')
s=once(s,'''alert.informativeText = update.manifest.notes?.isEmpty == false
            ? update.manifest.notes!
            : "Die neue Version kann jetzt automatisch geladen und installiert werden."''', '''alert.informativeText = update.manifest.localizedNotes''') if '?:UNUSED' in s else s
# The fallback literal was migrated above; replace the entire three-line expression.
s,n=re.subn(r'alert\.informativeText = update\.manifest\.notes\?\.isEmpty == false\n\s*\? update\.manifest\.notes!\n\s*: L10n\.source\("Die neue Version kann jetzt automatisch geladen und installiert werden\."\)', 'alert.informativeText = update.manifest.localizedNotes',s)
assert n==1, 'Offer-update notes not migrated'
s=s.replace('formatter.locale = Locale(identifier: "de_DE")', 'formatter.locale = L10n.locale')
changed['AppDelegate.swift']=s

s=changed['OutlookToolbarButtonController.swift']
s=once(s, 'let label = NSTextField(labelWithString: delayedTooltipText)', 'let label = NSTextField(labelWithString: L10n.render(delayedTooltipText))')
s=before(s, '    func hideDelayedTooltip() {', '''    func refreshLocalization() {
        hideDelayedTooltip()
        setAccessibilityLabel(L10n.render(delayedTooltipText))
    }

''')
s=s.replace('accessibilityDescription: tooltip)', 'accessibilityDescription: L10n.render(tooltip))')
s=s.replace('button.setAccessibilityLabel(tooltip)', 'button.setAccessibilityLabel(L10n.render(tooltip))')
s=before(s,'    private func hideAllTooltips() {', '''    func refreshLocalization() {
        [newButton, replyButton, replyAllButton, forwardButton, cancelButton, calendarButton, paymentButton]
            .forEach { $0.refreshLocalization() }
    }

''')
changed['OutlookToolbarButtonController.swift']=s

s=changed['CalendarManager.swift']
s=s.replace('<title>Replyzen</title>', '<title>ReplyZen</title>').replace(') Replyzen</h2>', ') ReplyZen</h2>')
s=s.replace('<p>\\(message)</p>', '<p>\\(L10n.render(message))</p>')
changed['CalendarManager.swift']=s

# Remote service error details stay verbatim and clearly identified as diagnostics.
s=changed['OpenAIClient.swift']
s=once(s, 'var errorDescription: String? { message }', '''var errorDescription: String? {
            L10n.isAppMessage(message) ? message : L10n.source("Anfrage fehlgeschlagen. Technische Details: {0}", message)
        }''')
changed['OpenAIClient.swift']=s

s=changed['UpdateManager.swift']
s=once(s, '        let notes: String?\n', '''        let notes: String?
        let notesLocalized: [String: String]?

        var localizedNotes: String {
            if let localized = notesLocalized?[L10n.language.rawValue], !localized.isEmpty { return localized }
            if let notes, !notes.isEmpty { return L10n.render(notes) }
            return L10n.tr("Die neue Version kann jetzt automatisch geladen und installiert werden.")
        }
''')
s=once(s, '            case notes\n', '            case notes\n            case notesLocalized = "notes_localized"\n')
changed['UpdateManager.swift']=s

# Date/time displays use the chosen interface locale; domain timezone is unchanged.
# App bundle, keychain, feed URL and model settings deliberately retain their identity.
info['CFBundleShortVersionString']='1.47.0'
info['CFBundleVersion']='48'
info['CFBundleLocalizations']=['en','de','es']
resources=APP/'Resources'
resources.mkdir(exist_ok=True)
for name,text in changed.items():
    if text != sources[name]: (APP/name).write_text(text)
(resources/'Localization.json').write_text(json.dumps(catalog,ensure_ascii=False,indent=2)+'\n')
(APP/'Info.plist').write_bytes(plistlib.dumps(info,sort_keys=False))

# Test executables are not app bundles. A compile-time test flag allows an explicit
# fixture catalog, while production always loads its signed bundled resource.
p=REPO/'tests/run-tests.sh'
s=p.read_text().replace('swiftc -parse-as-library', 'swiftc -DLOCALIZATION_TESTS -parse-as-library')
s=s.replace('"$SOURCE/app/ResponseJSON.swift"', '"$SOURCE/app/LocalizationCore.swift" "$SOURCE/app/ResponseJSON.swift"')
s=s.replace('python3 "$ROOT/tests/test_source_contracts.py"', 'export REPLYZEN_TEST_CATALOG="$SOURCE/app/Resources/Localization.json"\npython3 "$ROOT/tests/test_source_contracts.py"')
p.write_text(s)
p=REPO/'tests/run-workspace-tests.sh'
s=p.read_text().replace('swiftc -parse-as-library','swiftc -DLOCALIZATION_TESTS -parse-as-library')
s=s.replace('"$TMP/workspace-tests" "$SOURCE/.ui-previews"','REPLYZEN_TEST_CATALOG="$SOURCE/app/Resources/Localization.json" "$TMP/workspace-tests" "$SOURCE/.ui-previews"')
p.write_text(s)
p=REPO/'tests/test_source_contracts.py'
s=p.read_text().replace("'1.46.0'","'1.47.0'").replace("info['CFBundleVersion'], '47'","info['CFBundleVersion'], '48'")
p.write_text(s)
p=REPO/'tests/verify_update.py'
s=p.read_text().replace("'1.46.0'","'1.47.0'").replace("== 47","== 48").replace('Replyzen-update-1.46.zip','Replyzen-update-1.47.zip').replace('PASS: 1.46','PASS: 1.47')
s=s.replace("    binary = package.read", "    translations = json.loads(package.read('Replyzen.app/Contents/Resources/Localization.json'))\n    assert len(translations) >= 250\n    assert all(set(row) == {'de', 'en-US', 'es'} for row in translations.values())\n    assert set(manifest['notes_localized']) == {'de', 'en-US', 'es'}\n    binary = package.read")
p.write_text(s)
p=ROOT/'Build-CI.sh'
s=p.read_text()
s=once(s,'    "notes": (root / "Release-notes.txt").read_text(encoding="utf-8").strip(),','    "notes": (root / "Release-notes.txt").read_text(encoding="utf-8").strip(),\n    "notes_localized": json.loads((root / "Release-notes.localized.json").read_text(encoding="utf-8")),')
p.write_text(s)
print('Localized source occurrences:', counts)
print('Complete three-language keys:', len(catalog))
