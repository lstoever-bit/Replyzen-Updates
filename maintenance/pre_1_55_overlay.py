#!/usr/bin/env python3
from pathlib import Path
import sys
path = Path(sys.argv[1]) / "app" / "OverlayView.swift"
text = path.read_text(encoding="utf-8")
text = text.replace('        case .payment: return L10n.tr("Überweisung")\n', '')
path.write_text(text, encoding="utf-8")
