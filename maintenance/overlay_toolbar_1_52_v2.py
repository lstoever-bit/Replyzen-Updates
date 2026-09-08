#!/usr/bin/env python3
"""Run the 1.52 migration with an unambiguous controller insertion marker."""
from pathlib import Path

path = Path(__file__).with_name("overlay_toolbar_1_52.py")
source = path.read_text(encoding="utf-8")
old = 'toolbar = once(toolbar, "    func refreshLocalization() {\\n", methods + "    func refreshLocalization() {\\n")'
new = '''toolbar = once(
    toolbar,
    "    @objc private func paymentClicked() { paymentAction?() }\\n\\n    func refreshLocalization() {\\n",
    "    @objc private func paymentClicked() { paymentAction?() }\\n\\n" + methods + "    func refreshLocalization() {\\n"
)'''
if source.count(old) != 1:
    raise RuntimeError("Could not find the 1.52 controller insertion marker")
source = source.replace(old, new, 1)
exec(compile(source, str(path), "exec"), {"__name__": "__main__", "__file__": str(path)})
