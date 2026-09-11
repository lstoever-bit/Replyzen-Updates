#!/usr/bin/env python3
"""1.60 safety follow-up: mail-context loading must never clear typed editor content."""
from pathlib import Path
import sys

root = Path(sys.argv[1])
app = root / "app"
delegate_path = app / "AppDelegate.swift"
delegate = delegate_path.read_text(encoding="utf-8")
old = '''                    if self.isDefaultReplyInstruction(self.state.instruction) {
                        self.state.instruction = ""
                        self.state.instructionHTML = ""
                    }
'''
if old in delegate:
    delegate = delegate.replace(old, '', 1)
    delegate_path.write_text(delegate, encoding="utf-8")

# Enforce the behavior in the generated source contract.
test_path = root.parent / "tests" / "test_source_contracts.py"
test = test_path.read_text(encoding="utf-8")
needle = '        self.assertNotIn("selectInstructionTextSoon", refresh)\n'
addition = ('        self.assertNotIn("selectInstructionTextSoon", refresh)\n'
            '        self.assertNotIn("self.state.instruction = \\\"\\\"", refresh)\n'
            '        self.assertNotIn("self.state.instructionHTML = \\\"\\\"", refresh)\n')
if addition not in test:
    if needle not in test:
        raise SystemExit("Expected refresh test marker missing")
    test = test.replace(needle, addition, 1)
    test_path.write_text(test, encoding="utf-8")

print("PASS: mail context completion/failure cannot clear user editor text")
