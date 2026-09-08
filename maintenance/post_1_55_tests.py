#!/usr/bin/env python3
from pathlib import Path
import sys
root = Path(sys.argv[1]).parent
path = root / "tests" / "ClientDecoderChecks.swift"
text = path.read_text(encoding="utf-8")
text = text.replace(
    '        precondition(try extractOutputText(from: output) == "Hello\\nworld")\n',
    '        let outputText = try extractOutputText(from: output)\n        precondition(outputText == "Hello\\nworld")\n'
)
path.write_text(text, encoding="utf-8")
