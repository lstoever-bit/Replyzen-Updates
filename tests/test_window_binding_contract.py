#!/usr/bin/env python3
"""Ensure the tested window/state policies are wired to the actual AX transport."""
from pathlib import Path
import sys
app = Path(sys.argv[1]) / 'app'
adapter = (app / 'OutlookReplyInsertion.swift').read_text()
state = (app / 'ReplyInsertionPolicy.swift').read_text()
assert 'ReplyWindowTracker<AXUIElement, AXUIElement>' in adapter
observe = adapter[adapter.index('    private func observe()'):adapter.index('    private func resolveEditor(')]
assert 'if targetWindow == nil { targetWindow = window }' not in observe
assert observe.index('case .ready(let rebound):') < observe.index('targetWindow = window')
assert 'windowTracker.observe(' in observe
assert 'result.editorRebound = rebound' in observe
assert 'result.windowPending = true' in observe
paste = adapter[adapter.index('        case .paste:'):adapter.index('        case .complete:')]
assert paste.index('hasEditorFocus()') < paste.index('windowTracker.lockForPaste') < paste.index('pasted = true')
assert paste.count('pasteThroughOutlook()') == 1
assert 'completion(diagnostic == "R74-WINDOW" ? (windowFailure ?? diagnostic) : diagnostic)' in adapter
assert state.index('totalTicks > 100') < state.index('if observation.windowPending')
assert 'if observation.editorRebound && phase != .verifying' in state
assert 'phaseTicks = max(0, phaseTicks - 1)' in state
assert 'case .verifying:' in state and 'confirmsInsertion' in state
print('PASS: production AX adapter uses tested stable binding, pre-write lease, bounded wait and read-back')
