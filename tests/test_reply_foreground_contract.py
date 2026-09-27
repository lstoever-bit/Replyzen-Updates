#!/usr/bin/env python3
from pathlib import Path
import sys
app = Path(sys.argv[1]) / 'app'
delegate = (app / 'AppDelegate.swift').read_text()
adapter = (app / 'OutlookReplyInsertion.swift').read_text()
typography = (app / 'MailTypography.swift').read_text()
reply = delegate[delegate.index('    private func insertReply() {'):delegate.index('    private func insertForwardDraft() {')]
assert reply.index('MailTypography.payload(') < reply.index('panel.hide()') < reply.index('OutlookReplyInsertion.activateForReply(')
assert 'preparedPayload: preparedPayload' in reply
assert 'self.copyMailToPasteboard(plainText: reply, html: html)' not in reply
assert 'MailTypography.payload(' not in adapter
assert 'MailTypography.write(plainText:' not in adapter
paste = adapter[adapter.index('        case .paste:'):adapter.index('        case .complete:')]
assert paste.index('hasEditorFocus()') < paste.index('windowTracker.lockForPaste') < paste.index('pasted = true')
assert 'MailTypography.write(preparedPayload)' in paste
assert paste.count('pasteThroughOutlook()') == 1
tick = adapter[adapter.index('    private func tick()'):adapter.index('    private func holdUntilOutlookOwnsForeground()')]
assert tick.index('holdUntilOutlookOwnsForeground()') < tick.index('let observation = observe()') < tick.index('currentState.next(observation)')
assert 'guard observation.active else' in tick
assert 'guard !cancelled else { return }' in adapter[adapter.index('    private func scheduleTick()'):adapter.index('    private func tick()')]
writer = typography[typography.index('    static func write(_ value: Payload'):typography.index('    /// Inline Cocoa')]
assert 'payload(' not in writer and 'attributedString(' not in writer
assert 'activate(' not in writer and 'DispatchQueue' not in writer
print('PASS: production Reply prepares formats before handoff, pauses foreground safely, and retains one-paste/write-lease checks')
