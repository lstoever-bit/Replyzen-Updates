#!/usr/bin/env python3
"""Normalize 1.61 prompt layout and Swift request argument order after the main migration."""
from pathlib import Path
import sys

root = Path(sys.argv[1])
repo = root.parent
builder_path = root / "app" / "MailPromptBuilder.swift"
builder = builder_path.read_text(encoding="utf-8")
old = '''        let userPrompt = """
Language: \\(payload.language)
Tone: \\(payload.tone)
Compact: \\(compact)

Email context:
\\(context)

User instruction:
\\(payload.userText)
"""
'''
new = '''        var lines = [
            "Language: \\(payload.language)",
            "Tone: \\(payload.tone)",
            "Compact: \\(compact)",
            "",
            "Email context:"
        ]
        if !context.isEmpty {
            lines.append(context)
        }
        lines.append("")
        lines.append("User instruction:")
        lines.append(payload.userText)
        let userPrompt = lines.joined(separator: "\\n")
'''
if old in builder:
    builder = builder.replace(old, new, 1)
elif new not in builder:
    raise SystemExit("MailPromptBuilder is neither pre-fix nor already normalized")
builder_path.write_text(builder, encoding="utf-8")

client_path = root / "app" / "OpenAIClient.swift"
client = client_path.read_text(encoding="utf-8")
reply_old = '''            input: prompt.user,
            responseFormat: replyDraftResponseFormat,
            maxOutputTokens: payload.compact ? 340 : 700,
            lowVerbosity: true
'''
reply_new = '''            input: prompt.user,
            maxOutputTokens: payload.compact ? 340 : 700,
            lowVerbosity: true,
            responseFormat: replyDraftResponseFormat
'''
reply_old_count = client.count(reply_old)
reply_new_count = client.count(reply_new)
if reply_old_count == 2:
    client = client.replace(reply_old, reply_new)
elif not (reply_old_count == 0 and reply_new_count == 2):
    raise SystemExit(f"Unexpected Reply/Forward response-format call state: old={reply_old_count}, new={reply_new_count}")

new_mail_old = '''            input: prompt.user,
            responseFormat: newMailDraftResponseFormat,
            maxOutputTokens: payload.compact ? 380 : 760,
            lowVerbosity: true
'''
new_mail_new = '''            input: prompt.user,
            maxOutputTokens: payload.compact ? 380 : 760,
            lowVerbosity: true,
            responseFormat: newMailDraftResponseFormat
'''
new_mail_old_count = client.count(new_mail_old)
new_mail_new_count = client.count(new_mail_new)
if new_mail_old_count == 1:
    client = client.replace(new_mail_old, new_mail_new, 1)
elif not (new_mail_old_count == 0 and new_mail_new_count == 1):
    raise SystemExit(f"Unexpected New Mail response-format call state: old={new_mail_old_count}, new={new_mail_new_count}")
client_path.write_text(client, encoding="utf-8")

contracts_path = repo / "tests" / "test_source_contracts.py"
contracts = contracts_path.read_text(encoding="utf-8")
contracts = contracts.replace('self.assertIn("Language: \\(payload.language)", prompt_builder)', 'self.assertIn(r"Language: \\(payload.language)", prompt_builder)')
contracts = contracts.replace('self.assertIn("Tone: \\(payload.tone)", prompt_builder)', 'self.assertIn(r"Tone: \\(payload.tone)", prompt_builder)')
contracts = contracts.replace('self.assertIn("Compact: \\(compact)", prompt_builder)', 'self.assertIn(r"Compact: \\(compact)", prompt_builder)')
contracts_path.write_text(contracts, encoding="utf-8")
print("ReplyZen 1.61 prompt normalization is applied and idempotent")
