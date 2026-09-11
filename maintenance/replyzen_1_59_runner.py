#!/usr/bin/env python3
"""Run the 1.59 migration with the prompt insertion limited to generateReply only."""
from pathlib import Path
import sys

script = Path(__file__).with_name("replyzen_1_59_mail_context_and_editor.py")
source = script.read_text(encoding="utf-8")
old = 'client = replace_once(client, needle, replacement, "reply prompt priority")'
new = 'client = client.replace(needle, replacement, 1)'
if old not in source and new not in source:
    raise SystemExit("ReplyZen 1.59 migration prompt marker changed unexpectedly")
source = source.replace(old, new, 1)
namespace = {"__name__": "__main__", "__file__": str(script)}
exec(compile(source, str(script), "exec"), namespace, namespace)
