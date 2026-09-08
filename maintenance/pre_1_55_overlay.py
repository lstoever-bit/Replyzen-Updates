#!/usr/bin/env python3
from pathlib import Path
import sys
root = Path(sys.argv[1]) / "app"

path = root / "OverlayView.swift"
text = path.read_text(encoding="utf-8")
text = text.replace('        case .payment: return L10n.tr("Überweisung")\n', '')
path.write_text(text, encoding="utf-8")

path = root / "WorkspaceComponents.swift"
text = path.read_text(encoding="utf-8")
text = text.replace('        case .paymentPreview: return L10n.tr("Daten prüfen")\n', '')
path.write_text(text, encoding="utf-8")
