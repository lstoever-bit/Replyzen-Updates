#!/usr/bin/env python3
"""Ensure the ChatGPT data block contains only user-requested content/settings."""
from pathlib import Path
import sys

root = Path(sys.argv[1])
app = root / "app"

delegate_path = app / "AppDelegate.swift"
delegate = delegate_path.read_text(encoding="utf-8")
delegate = delegate.replace(
    '    private func makeTransferPayload(action: String, mailThread: String?) -> ChatGPTTransferPayload? {\n',
    '    private func makeTransferPayload(mailThread: String?) -> ChatGPTTransferPayload? {\n',
)
delegate = delegate.replace('            action: action,\n', '')
delegate = delegate.replace(
    '        let action = state.replyScope == .all ? "reply_all" : "reply"\n        guard let payload = makeTransferPayload(action: action, mailThread: state.mailText) else { return }\n',
    '        guard let payload = makeTransferPayload(mailThread: state.mailText) else { return }\n',
)
delegate = delegate.replace(
    '        guard let payload = makeTransferPayload(action: "new_mail", mailThread: nil) else { return }\n',
    '        guard let payload = makeTransferPayload(mailThread: nil) else { return }\n',
)
delegate = delegate.replace(
    '        guard let payload = makeTransferPayload(action: "forward", mailThread: state.mailText) else { return }\n',
    '        guard let payload = makeTransferPayload(mailThread: state.mailText) else { return }\n',
)
if 'makeTransferPayload(action:' in delegate or 'action: action' in delegate:
    raise SystemExit('Internal action metadata remains in mail payload construction')
delegate_path.write_text(delegate, encoding="utf-8")

# Keep the regression contract strict: no action metadata may be present in the
# user-data payload or payload construction.
test_path = root.parent / "tests" / "test_source_contracts.py"
test = test_path.read_text(encoding="utf-8")
for old in [
    '        self.assertIn(\'action = state.replyScope == .all ? "reply_all" : "reply"\', delegate)\n',
    '        self.assertIn(\'action: "new_mail", mailThread: nil\', delegate)\n',
    '        self.assertIn(\'action: "forward", mailThread: state.mailText\', delegate)\n',
]:
    test = test.replace(old, '')
marker = '        self.assertIn("TransferPreviewWindowController", delegate)\n'
addition = (
    marker +
    '        self.assertNotIn("let action:", payload)\n' +
    '        self.assertNotIn("\\\"action\\\"", payload)\n' +
    '        self.assertNotIn("makeTransferPayload(action:", delegate)\n' +
    '        self.assertIn("makeTransferPayload(mailThread: state.mailText)", delegate)\n' +
    '        self.assertIn("makeTransferPayload(mailThread: nil)", delegate)\n'
)
if 'self.assertNotIn("let action:", payload)' not in test:
    if marker not in test:
        raise SystemExit('Expected transfer preview test marker missing')
    test = test.replace(marker, addition, 1)
test_path.write_text(test, encoding="utf-8")
print("PASS: ChatGPT transfer data has no internal action metadata")
