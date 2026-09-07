from pathlib import Path
import sys

root = Path(sys.argv[1])


def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f"{label} not found")
    return text.replace(old, new, 1)

# Make the selected Replyzen language authoritative. The language used in the
# user's free-form instruction is input language only and must not override the
# DE / US-English selector.
p = root / "app" / "OpenAIClient.swift"
s = p.read_text()
old = '''    private func languageInstruction(for language: AppState.ReplyLanguage, purpose: String) -> String {\n        switch language {\n        case .german:\n            return \"Write the entire \\(purpose) in natural German. Do not switch to English unless the user explicitly asks for it.\"\n        case .usEnglish:\n            return \"Write the entire \\(purpose) in natural US English. Use American spelling and phrasing. Do not switch to German unless the user explicitly asks for it.\"\n        }\n    }\n'''
new = '''    private func languageInstruction(for language: AppState.ReplyLanguage, purpose: String) -> String {\n        switch language {\n        case .german:\n            return \"FINAL OUTPUT LANGUAGE IS GERMAN. Write the entire \\(purpose) in natural German. The USER INSTRUCTION may be written in any language; treat its language only as input and translate its requested meaning into German. Never switch the final email to another language because the instruction itself is written in that language. Preserve exact names, brands, URLs, email addresses and explicitly requested verbatim quotations.\"\n        case .usEnglish:\n            return \"FINAL OUTPUT LANGUAGE IS US ENGLISH. Write the entire \\(purpose) in natural US English using American spelling and phrasing. The USER INSTRUCTION may be written in any language; treat its language only as input and translate its requested meaning into US English. Never switch the final email to German or another language because the instruction itself is written in that language. Preserve exact names, brands, URLs, email addresses and explicitly requested verbatim quotations.\"\n        }\n    }\n'''
s = must_replace(s, old, new, "strict selected language")
p.write_text(s)

# Version + build.
p = root / "app" / "Info.plist"
s = p.read_text()
s = must_replace(s, "<string>1.25.0</string>", "<string>1.26.0</string>", "Info version")
s = must_replace(s, "<string>26</string>", "<string>27</string>", "Info build")
p.write_text(s)

# Update package name and release notes.
p = root / "Build-CI.sh"
s = p.read_text()
s = s.replace("Replyzen-update-1.25.zip", "Replyzen-update-1.26.zip")
s = s.replace(
    '"notes": "Replyzen 1.25: Mail ist jetzt wirklich eine einzige Form. Reply und New Mail schalten nur das Verhalten derselben Eingabemaske um. Die Überschrift über dem Textfeld ist entfernt. Wenn keine Outlook-Mail erkannt wird, ist Reply ausgeblendet und es erscheint nur ein kleiner Hinweis."',
    '"notes": "Replyzen 1.26: Die ausgewählte Sprache ist jetzt strikt die Ausgabesprache. Eine deutsche Anweisung wird bei ausgewähltem US English automatisch als Inhalt verstanden und die fertige Mail auf US English formuliert, und umgekehrt."'
)
p.write_text(s)
