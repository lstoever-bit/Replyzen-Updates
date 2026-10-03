#!/usr/bin/env python3
"""Build a separate UI shell with the new native mail core. Never edits source-current."""
from pathlib import Path
import shutil, sys, plistlib, hashlib, json
root = Path(__file__).resolve().parent.parent
out = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root / '.native-build'
source = root / 'source-current'
if out == source.resolve() or source.resolve() in out.parents:
    raise SystemExit('Output must be separate from source-current')
expected = '55518f72700ad1cb34700841a7bf44ff0d3e9908'
raw = (source / 'app/AppDelegate.swift').read_bytes()
blob = hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest()
if blob != expected: raise SystemExit(f'Baseline drift: AppDelegate {blob}')
if out.exists(): shutil.rmtree(out)
shutil.copytree(source, out, ignore=shutil.ignore_patterns('.build*', '*.zip', 'update.json'))
app = out / 'app'
s = raw.decode()

def replace_block(text, start, end, new):
    a = text.index(start); b = text.index(end, a)
    return text[:a] + new + text[b:]

s = s.replace('    private var activeReplyInsertion: OutlookReplyInsertion?\n', '''    private let nativeOutlook = NativeOutlookBridge()
    private var nativeContext: NativeMailContext?
    private var nativeGenerationSource: NativeMessageToken?
    private var nativeReplyMode: NativeMailMode = .reply
    private var nativeOperationID = UUID()
    private var nativeTransaction: NativeMailTransaction?
    private var nativeRequest: NativeMailRequest?
''')
s = s.replace('        activeReplyInsertion?.cancel()\n        activeReplyInsertion = nil\n', '        nativeOperationID = UUID()\n')
s = s.replace('        configureUpdates()\n', '        // Preview: no automatic production updater.\n')
s = s.replace('        _ = loginItem.enableAtLoginIfPossible()\n', '        // Preview: do not register a second login item.\n')
s = replace_block(s, '        let updates = NSMenuItem(', '        let quit = NSMenuItem(', '')
s = replace_block(s, '    private func refreshMailContext() {', '    private func generateCurrentOutput() {', '''    private func refreshMailContext() {
        guard !isLoadingMail, !isRunningFlow else { return }
        nativeContext = nil
        state.mailText = ""
        if requestedMailMode == .newMail || state.outputMode == .newMail {
            requestedMailMode = nil
            state.mailStatus = .unavailable("Neue Mail: kein Original erforderlich.")
            return
        }
        isLoadingMail = true
        state.mailStatus = .loading
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.isLoadingMail = false; self.requestedMailMode = nil }
            do {
                let context = try self.nativeOutlook.capture()
                self.nativeContext = context
                self.state.mailText = context.plainText
                self.state.mailStatus = .available
                if let language = self.detectReplyLanguage(in: context.plainText) { self.state.replyLanguage = language }
            } catch {
                self.state.mailStatus = .unavailable(error.localizedDescription)
            }
        }
    }

''')
for signature in ['    private func performReply(_ payload: ChatGPTTransferPayload, apiKey: String) {',
                  '    private func performForward(_ payload: ChatGPTTransferPayload, apiKey: String) {',
                  '    private func performNewMail(_ payload: ChatGPTTransferPayload, apiKey: String) {']:
    assert s.count(signature) == 1
    s = s.replace(signature, signature + '''
        nativeOperationID = UUID()
        nativeTransaction = nil
        nativeRequest = nil
        nativeGenerationSource = nativeContext?.token
        nativeReplyMode = state.replyScope == .all ? .replyAll : .reply
''')
for begin, end in [('    private func performReply(', '    private func generateNewMail('),
                   ('    private func performNewMail(', '    private func forwardWithNote('),
                   ('    private func performForward(', '    private func generateCalendarSuggestion(')]:
    a=s.index(begin); b=s.index(end,a)
    block=s[a:b]
    block=block.replace('        isRunningFlow = true', '        let generationID = nativeOperationID\n        isRunningFlow = true', 1)
    block=block.replace('                guard let self else { return }', '                guard let self, self.nativeOperationID == generationID else { return }',1)
    s=s[:a]+block+s[b:]
s = s.replace('guard !state.mailText.isEmpty, activeSnapshot != nil else {', 'guard !state.mailText.isEmpty, nativeContext != nil else {')
s = replace_block(s, '    private func insertReply() {', '    private func copyMailToPasteboard(', '''    private func insertReply() { insertNativeMail(mode: nativeReplyMode) }
    private func insertForwardDraft() { insertNativeMail(mode: .forward) }
    private func insertNewMail() { insertNativeMail(mode: .newMail) }

    private func insertNativeMail(mode: NativeMailMode) {
        guard !isRunningFlow else { return }
        let note = state.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        if nativeRequest == nil {
            let formatted = MailTypography.payload(plainText: note, html: state.replyHTML)
            nativeRequest = NativeMailRequest(operationID: nativeOperationID, mode: mode,
                source: mode == .newMail ? nil : nativeGenerationSource,
                subject: state.newMailSubject, note: note, noteHTML: formatted.html,
                reminderBCC: reminderBCCAddress())
        }
        guard let request = nativeRequest else { return }
        let transaction = nativeTransaction ?? NativeMailTransaction(transport: nativeOutlook)
        nativeTransaction = transaction
        let operationID = nativeOperationID
        isRunningFlow = true
        state.stage = .inserting
        state.statusText = "Outlook-Entwurf wird direkt vorbereitet"
        toolbarButton.setSuppressed(true)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.nativeOperationID == operationID else { return }
            do {
                _ = try transaction.run(request)
                guard self.nativeOperationID == operationID else { return }
                self.panel.hide()
                self.isRunningFlow = false
                self.state.stage = .idle
                self.toolbarButton.setSuppressed(false)
            } catch {
                guard self.nativeOperationID == operationID else { return }
                self.copyMailToPasteboard(plainText: note, html: self.state.replyHTML)
                self.showError(error.localizedDescription)
            }
        }
    }

''')
s = replace_block(s, '    private func quickDecline() {', '    @objc private func menuSettings()', '''    private func quickDecline() {
        guard !isRunningFlow else { return }
        guard let apiKey = keychain.loadAPIKey() else { openWorkspace(); return }
        do {
            let context = try nativeOutlook.capture()
            nativeGenerationSource = context.token
            nativeReplyMode = .replyAll
            nativeOperationID = UUID()
            nativeTransaction = nil
            nativeRequest = nil
            let operation = nativeOperationID
            isRunningFlow = true
            toolbarButton.setSuppressed(true)
            openAI.generateQuickDecline(apiKey: apiKey, mailText: context.plainText) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.nativeOperationID == operation else { return }
                    self.isRunningFlow = false
                    switch result {
                    case .success(let text):
                        self.state.reply = text
                        self.state.replyHTML = ""
                        self.insertReply()
                    case .failure(let error): self.showError(error.localizedDescription)
                    }
                }
            }
        } catch { showError(error.localizedDescription) }
    }

''')
(app / 'AppDelegate.swift').write_text(s)
for name in ['OutlookReplyInsertion', 'ReplyInsertionPolicy', 'ReplyWindowTracker', 'ReplyForegroundGuard', 'ReplyRecoveryRules', 'ReplyEditorSupport']:
    (app / (name + '.swift')).unlink(missing_ok=True)
for sub in ['Core', 'Mac']:
    for p in (root / 'rewrite' / sub).glob('*.swift'): shutil.copy2(p, app / p.name)
shutil.copy2(root/'rewrite/Scripts/Outlook.applescript', app/'Resources/Outlook.applescript')
info = plistlib.loads((app / 'Info.plist').read_bytes())
info.update(CFBundleIdentifier='com.lstoever.replyzen.nativepreview', CFBundleDisplayName='ReplyZen Native Preview', CFBundleShortVersionString='2.0.0', CFBundleVersion='200', NSAppleEventsUsageDescription='ReplyZen liest die ausgewaehlte Outlook-Mail und erstellt Antwort-, Weiterleitungs- und neue Entwuerfe. Es sendet keine E-Mails automatisch.')
(app / 'Info.plist').write_bytes(plistlib.dumps(info, sort_keys=False))
for name in ['OpenAIClient.swift', 'KeychainStore.swift', 'NewMailSubject.swift', 'MailTypography.swift', 'MailPromptBuilder.swift', 'CalendarManager.swift']:
    assert (app / name).read_bytes() == (source / 'app' / name).read_bytes(), name
assert (source / 'app/AppDelegate.swift').read_bytes() == raw
assert 'OutlookReplyInsertion' not in s
native = s[s.index('    private func insertReply()'):s.index('    private func copyMailToPasteboard(')]
for forbidden in ['keyboard.', 'focusCompose', 'activeSnapshot', 'foreground', 'sendCommand', 'setCompose']:
    assert forbidden not in native, forbidden
print('Assembled isolated native UI shell at', out)
