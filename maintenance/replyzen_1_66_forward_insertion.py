#!/usr/bin/env python3
"""ReplyZen 1.66: make Forward open/verify its Outlook composer before inserting text."""
from pathlib import Path
import json
import plistlib
import sys

root = Path(sys.argv[1])
repo = root.parent
app = root / "app"


def replace_once(text: str, before: str, after: str, label: str) -> str:
    count = text.count(before)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}")
    return text.replace(before, after, 1)


info_path = app / "Info.plist"
info = plistlib.loads(info_path.read_bytes())

if info.get("CFBundleShortVersionString") == "1.66.0" and str(info.get("CFBundleVersion")) == "67":
    delegate = (app / "AppDelegate.swift").read_text(encoding="utf-8")
    outlook = (app / "OutlookAccessibility.swift").read_text(encoding="utf-8")
    matcher = (app / "OutlookReplyControlMatcher.swift").read_text(encoding="utf-8")
    required = [
        "openForwardComposer(from: snapshot)",
        "hasOpenedForwardComposer(since: snapshot)",
        "populateForwardDraft(body: body, html: html, snapshot: snapshot, attempt: 0)",
        "attempt < 12",
    ]
    if not all(token in delegate for token in required):
        raise SystemExit("ReplyZen reports 1.66 but the Forward insertion fix is incomplete")
    if "func openForwardComposer(from snapshot: Snapshot)" not in outlook or "func hasOpenedForwardComposer(since snapshot: Snapshot)" not in outlook:
        raise SystemExit("ReplyZen reports 1.66 but Outlook Forward composer helpers are missing")
    if "static func forwardScore(metadata: String)" not in matcher:
        raise SystemExit("ReplyZen reports 1.66 but Forward control matching is missing")
    print("ReplyZen 1.66 migration already applied")
    raise SystemExit(0)

if info.get("CFBundleShortVersionString") != "1.65.0" or str(info.get("CFBundleVersion")) != "66":
    raise SystemExit("Unexpected ReplyZen source version; refusing to modify")

# Extend the existing localized Outlook action matcher. Reply matching is kept
# behaviorally identical; Forward gets its own independent score.
matcher_path = app / "OutlookReplyControlMatcher.swift"
matcher_path.write_text('''import Foundation

/// Scores Outlook accessibility controls without depending on Outlook's current UI language.
enum OutlookReplyControlMatcher {
    private static func normalized(_ metadata: String) -> String {
        metadata
            .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func score(metadata: String, replyAll: Bool) -> Int {
        let normalized = normalized(metadata)
        let allPhrases = ["reply all", "replyall", "allen antworten", "antwort an alle", "responder a todos"]
        let replyPhrases = ["reply", "antworten", "responder"]
        let containsAll = allPhrases.contains { normalized.contains($0) }

        if replyAll {
            guard containsAll else { return 0 }
            if allPhrases.contains(normalized) { return 120 }
            if normalized.contains("replyall") { return 115 }
            return 90
        }

        guard !containsAll else { return 0 }
        guard replyPhrases.contains(where: { normalized.contains($0) }) else { return 0 }
        if replyPhrases.contains(normalized) { return 120 }
        if normalized.contains("forward") || normalized.contains("weiterleiten") || normalized.contains("reenviar") { return 0 }
        return 70
    }

    static func forwardScore(metadata: String) -> Int {
        let normalized = normalized(metadata)
        let phrases = ["forward", "weiterleiten", "reenviar"]
        guard phrases.contains(where: { normalized.contains($0) }) else { return 0 }
        if phrases.contains(normalized) { return 120 }
        if normalized.contains("reply") || normalized.contains("antwort") || normalized.contains("responder") { return 0 }
        return 80
    }
}
''', encoding="utf-8")

# Add Forward-specific composer opening without touching the working Reply path.
outlook_path = app / "OutlookAccessibility.swift"
outlook = outlook_path.read_text(encoding="utf-8")
needle = '''    func setComposeBCCValue(_ bcc: String) -> Bool {\n'''
forward_helpers = '''    func hasOpenedForwardComposer(since snapshot: Snapshot) -> Bool {\n        guard let focused = focusedOutlookWindow() else { return false }\n\n        // Detached compose windows are the normal Legacy Outlook behavior.\n        if !containsSameElement(snapshot.windows, focused) {\n            return true\n        }\n\n        // Some Outlook builds compose inline in the source window. Only consider\n        // that ready once Outlook exposes its native Send/Senden/Enviar control.\n        return looksLikeComposeWindow(focused)\n    }\n\n    func openForwardComposer(from snapshot: Snapshot) -> Bool {\n        guard let sourceWindow = snapshot.windows.first else { return false }\n        activateOutlook(pid: snapshot.pid)\n\n        let appElement = AXUIElementCreateApplication(snapshot.pid)\n        _ = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, sourceWindow)\n        _ = AXUIElementPerformAction(sourceWindow, kAXRaiseAction as CFString)\n        if looksLikeMainOutlookWindow(sourceWindow) {\n            focusSelectedMessageRow(in: sourceWindow)\n        }\n\n        var stack: [AXUIElement] = [sourceWindow]\n        var visited = 0\n        var best: (element: AXUIElement, score: Int)?\n        while let element = stack.popLast(), visited < 16_000 {\n            visited += 1\n            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""\n            if role == "AXButton" || role == "AXMenuButton" || role == "AXLink" || role == "AXMenuItem" {\n                let score = OutlookReplyControlMatcher.forwardScore(metadata: composeMetadata(for: element))\n                if score > 0 && (best == nil || score > best!.score) {\n                    best = (element, score)\n                }\n            }\n            for child in children(of: element).reversed() { stack.append(child) }\n        }\n\n        guard let best else { return false }\n        return AXUIElementPerformAction(best.element, kAXPressAction as CFString) == .success\n    }\n\n'''
outlook = replace_once(outlook, needle, forward_helpers + needle, "Forward composer helpers")
outlook_path.write_text(outlook, encoding="utf-8")

# Replace only the Forward insertion block. It now mirrors Reply's proven
# open -> verify -> keyboard fallback -> populate lifecycle while leaving Reply unchanged.
delegate_path = app / "AppDelegate.swift"
delegate = delegate_path.read_text(encoding="utf-8")
start = delegate.index("    private func insertForwardDraft() {")
end = delegate.index("    private func insertNewMail() {", start)
old_forward = delegate[start:end]
new_forward = '''    private func insertForwardDraft() {\n        guard let snapshot = activeSnapshot else {\n            state.stage = .instruction\n            state.mailStatus = .unavailable(L10n.source("Die ursprüngliche Outlook-Mail ist nicht mehr verfügbar. Bitte erneut laden."))\n            return\n        }\n\n        let body = state.reply.trimmingCharacters(in: .whitespacesAndNewlines)\n        let html = state.replyHTML.trimmingCharacters(in: .whitespacesAndNewlines)\n        guard !body.isEmpty else { return }\n\n        guard outlook.isTrusted() else {\n            copyMailToPasteboard(plainText: body, html: html)\n            showError(L10n.source("Replyzen braucht Bedienungshilfen, um den Forward automatisch in Outlook vorzubereiten. Dein Text wurde in die Zwischenablage kopiert."))\n            return\n        }\n\n        state.stage = .inserting\n        state.statusText = L10n.source("Outlook Forward wird geöffnet; Thread und Anhänge bleiben erhalten")\n        isRunningFlow = true\n        toolbarButton.setSuppressed(true)\n\n        // Keep the generated rich text ready before Outlook changes focus. The\n        // native Forward composer is responsible for retaining the original thread\n        // and attachments; ReplyZen inserts only its note above that content.\n        copyMailToPasteboard(plainText: body, html: html)\n        panel.hide()\n        outlook.activateOutlook(pid: snapshot.pid)\n\n        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in\n            guard let self else { return }\n            _ = self.outlook.openForwardComposer(from: snapshot)\n\n            // Match the reliable Reply lifecycle: prefer Outlook's native Forward\n            // control, verify that a composer really opened, and use Cmd+J only as\n            // a fallback. This prevents population from racing the source message.\n            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in\n                guard let self else { return }\n                if !self.outlook.hasOpenedForwardComposer(since: snapshot) {\n                    self.keyboard.sendCommandJ()\n                }\n                self.populateForwardDraft(body: body, html: html, snapshot: snapshot, attempt: 0)\n            }\n        }\n    }\n\n    private func populateForwardDraft(body: String, html: String, snapshot: OutlookAccessibility.Snapshot, attempt: Int) {\n        let delay = attempt == 0 ? 0.45 : 0.25\n        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in\n            guard let self else { return }\n\n            // Never paste into the original message/read pane. Wait until Outlook\n            // has actually exposed a detached or inline compose window.\n            guard self.outlook.hasOpenedForwardComposer(since: snapshot) else {\n                if attempt < 12 {\n                    self.populateForwardDraft(body: body, html: html, snapshot: snapshot, attempt: attempt + 1)\n                    return\n                }\n                self.copyMailToPasteboard(plainText: body, html: html)\n                self.isRunningFlow = false\n                self.toolbarButton.setSuppressed(false)\n                self.showError(L10n.source("Outlook hat den Forward-Editor nicht geöffnet. Der Text wurde in die Zwischenablage kopiert."))\n                return\n            }\n\n            if let reminder = self.reminderBCCAddress() {\n                _ = self.outlook.setComposeBCCValue(reminder)\n            }\n\n            if self.outlook.focusComposeBodyField() {\n                // The native Forward already contains the original thread. Put the\n                // insertion point at the top and paste only ReplyZen's text plus a\n                // two-line separator, preserving both HTML formatting and line breaks.\n                self.keyboard.sendCommandUp()\n                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in\n                    guard let self else { return }\n                    let plain = body + "\\n\\n"\n                    let rich = html.isEmpty ? "" : html + "<br><br>"\n                    self.copyMailToPasteboard(plainText: plain, html: rich)\n                    self.keyboard.sendCommandV()\n                    self.finishNewMailInsertion()\n                }\n                return\n            }\n\n            // Legacy Outlook sometimes has a native HTML editor that Accessibility\n            // cannot identify as a body. After a couple of normal attempts, use the\n            // reliable Subject -> Tab route, then move to the top before pasting.\n            if attempt >= 2, self.outlook.focusComposeSubjectField() {\n                self.keyboard.sendTab()\n                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in\n                    guard let self else { return }\n                    self.keyboard.sendCommandUp()\n                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in\n                        guard let self else { return }\n                        let plain = body + "\\n\\n"\n                        let rich = html.isEmpty ? "" : html + "<br><br>"\n                        self.copyMailToPasteboard(plainText: plain, html: rich)\n                        self.keyboard.sendCommandV()\n                        self.finishNewMailInsertion()\n                    }\n                }\n                return\n            }\n\n            if attempt < 12 {\n                self.populateForwardDraft(body: body, html: html, snapshot: snapshot, attempt: attempt + 1)\n                return\n            }\n\n            self.copyMailToPasteboard(plainText: body, html: html)\n            self.isRunningFlow = false\n            self.toolbarButton.setSuppressed(false)\n            self.showError(L10n.source("Der Forward wurde in Outlook geöffnet, aber Replyzen konnte den Text nicht automatisch über dem Thread einsetzen. Der Text liegt in der Zwischenablage."))\n        }\n    }\n\n'''
if old_forward.count("sendCommandJ()") != 1 or "populateForwardDraft(body: body, html: html, attempt: 0)" not in old_forward:
    raise RuntimeError("Forward insertion block did not match the expected 1.65 implementation")
delegate = delegate[:start] + new_forward + delegate[end:]
delegate_path.write_text(delegate, encoding="utf-8")

# Version.
info["CFBundleShortVersionString"] = "1.66.0"
info["CFBundleVersion"] = "67"
info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=False))

# Regression/source contracts: preserve Reply assertions and add Forward-specific checks.
contracts_path = repo / "tests" / "test_source_contracts.py"
contracts = contracts_path.read_text(encoding="utf-8")
contracts = contracts.replace('self.assertEqual(info["CFBundleShortVersionString"], "1.65.0")', 'self.assertEqual(info["CFBundleShortVersionString"], "1.66.0")')
contracts = contracts.replace('self.assertEqual(info["CFBundleVersion"], "66")', 'self.assertEqual(info["CFBundleVersion"], "67")')
needle = '''    def test_calendar_invite_reader(self):\n'''
forward_test = '''    def test_forward_insertion_matches_reply_lifecycle(self):\n        delegate = self.read("AppDelegate.swift")\n        outlook = self.read("OutlookAccessibility.swift")\n        matcher = self.read("OutlookReplyControlMatcher.swift")\n        self.assertIn("func openForwardComposer(from snapshot: Snapshot)", outlook)\n        self.assertIn("func hasOpenedForwardComposer(since snapshot: Snapshot)", outlook)\n        self.assertIn("OutlookReplyControlMatcher.forwardScore", outlook)\n        self.assertIn("static func forwardScore(metadata: String)", matcher)\n        forward = delegate[delegate.index("private func insertForwardDraft()") : delegate.index("private func insertNewMail()") ]\n        self.assertIn("openForwardComposer(from: snapshot)", forward)\n        self.assertIn("hasOpenedForwardComposer(since: snapshot)", forward)\n        self.assertIn("self.keyboard.sendCommandJ()", forward)\n        self.assertIn("snapshot: snapshot, attempt: 0", forward)\n        self.assertIn("attempt < 12", forward)\n        self.assertIn('let plain = body + "\\\\n\\\\n"', forward)\n        self.assertIn('html + "<br><br>"', forward)\n        self.assertIn("self.keyboard.sendCommandUp()", forward)\n        reply = delegate[delegate.index("private func insertReply()") : delegate.index("private func insertForwardDraft()") ]\n        self.assertIn("openReplyComposer(replyAll: replyAll, from: snapshot)", reply)\n        self.assertIn("hasOpenedReplyComposer(since: snapshot)", reply)\n\n'''
contracts = replace_once(contracts, needle, forward_test + needle, "Forward source contract")
contracts_path.write_text(contracts, encoding="utf-8")

behavior_path = repo / "tests" / "ReplyBehaviorTests.swift"
behavior = behavior_path.read_text(encoding="utf-8")
behavior = replace_once(
    behavior,
'''        checkReplyControlMatching()\n        print("PASS: newest-message language detection and Reply/Reply All control matching")\n''',
'''        checkReplyControlMatching()\n        checkForwardControlMatching()\n        print("PASS: newest-message language detection and Reply/Reply All/Forward control matching")\n''',
    "Forward matcher test invocation",
)
behavior = replace_once(
    behavior,
'''    private static func checkReplyControlMatching() {\n        precondition(OutlookReplyControlMatcher.score(metadata: "Reply", replyAll: false) > 0)\n        precondition(OutlookReplyControlMatcher.score(metadata: "Reply All", replyAll: false) == 0)\n        precondition(OutlookReplyControlMatcher.score(metadata: "Reply All", replyAll: true) > 0)\n        precondition(OutlookReplyControlMatcher.score(metadata: "Allen antworten", replyAll: true) > 0)\n        precondition(OutlookReplyControlMatcher.score(metadata: "Responder a todos", replyAll: true) > 0)\n        precondition(OutlookReplyControlMatcher.score(metadata: "Responder", replyAll: false) > 0)\n        precondition(OutlookReplyControlMatcher.score(metadata: "Forward", replyAll: false) == 0)\n    }\n''',
'''    private static func checkReplyControlMatching() {\n        precondition(OutlookReplyControlMatcher.score(metadata: "Reply", replyAll: false) > 0)\n        precondition(OutlookReplyControlMatcher.score(metadata: "Reply All", replyAll: false) == 0)\n        precondition(OutlookReplyControlMatcher.score(metadata: "Reply All", replyAll: true) > 0)\n        precondition(OutlookReplyControlMatcher.score(metadata: "Allen antworten", replyAll: true) > 0)\n        precondition(OutlookReplyControlMatcher.score(metadata: "Responder a todos", replyAll: true) > 0)\n        precondition(OutlookReplyControlMatcher.score(metadata: "Responder", replyAll: false) > 0)\n        precondition(OutlookReplyControlMatcher.score(metadata: "Forward", replyAll: false) == 0)\n    }\n\n    private static func checkForwardControlMatching() {\n        precondition(OutlookReplyControlMatcher.forwardScore(metadata: "Forward") > 0)\n        precondition(OutlookReplyControlMatcher.forwardScore(metadata: "Weiterleiten") > 0)\n        precondition(OutlookReplyControlMatcher.forwardScore(metadata: "Reenviar") > 0)\n        precondition(OutlookReplyControlMatcher.forwardScore(metadata: "Forward message") > 0)\n        precondition(OutlookReplyControlMatcher.forwardScore(metadata: "Reply") == 0)\n        precondition(OutlookReplyControlMatcher.forwardScore(metadata: "Allen antworten") == 0)\n    }\n''',
    "Forward matcher assertions",
)
behavior_path.write_text(behavior, encoding="utf-8")

verify_path = repo / "tests" / "verify_update.py"
verify = verify_path.read_text(encoding="utf-8")
verify = verify.replace("manifest['version'] == '1.65.0' and manifest['build'] == 66", "manifest['version'] == '1.66.0' and manifest['build'] == 67")
verify = verify.replace("manifest['download_url'] == 'Replyzen-update-1.65.zip'", "manifest['download_url'] == 'Replyzen-update-1.66.zip'")
verify = verify.replace("PASS: 1.65 version/build", "PASS: 1.66 version/build")
verify_path.write_text(verify, encoding="utf-8")

notes_de = "ReplyZen 1.66: Forward verwendet jetzt denselben robusten Outlook-Öffnungsablauf wie Reply. ReplyZen öffnet zunächst gezielt den nativen Weiterleiten-Composer, prüft, ob der Editor wirklich bereit ist, und nutzt Cmd+J nur noch als Fallback. Der erzeugte ReplyZen-Text wird anschließend formatiert mit den vorhandenen Zeilenumbrüchen oberhalb des unveränderten weitergeleiteten Mailverlaufs eingefügt. Reply und die übrigen Mail-Funktionen bleiben unverändert."
notes_en = "ReplyZen 1.66: Forward now uses the same robust Outlook opening lifecycle as Reply. ReplyZen first opens the native Forward composer, verifies that the editor is actually ready, and uses Cmd+J only as a fallback. The generated ReplyZen text is then inserted with formatting and line breaks above the unchanged forwarded message thread. Reply and all other mail functions remain unchanged."
notes_es = "ReplyZen 1.66: Reenviar ahora usa el mismo flujo robusto de apertura de Outlook que Responder. ReplyZen abre primero el editor nativo de reenvío, comprueba que esté realmente listo y usa Cmd+J solo como alternativa. Después inserta el texto generado, conservando formato y saltos de línea, encima del hilo reenviado sin modificar. Responder y las demás funciones de correo permanecen sin cambios."
(root / "Release-notes.txt").write_text(notes_de + "\n", encoding="utf-8")
(root / "Release-notes.localized.json").write_text(json.dumps({"de": notes_de, "en-US": notes_en, "es": notes_es}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

print("Migrated ReplyZen to 1.66.0 / build 67")
