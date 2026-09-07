from pathlib import Path
import sys

root = Path(sys.argv[1])

# 1) Calendar extraction: use a smaller extraction-focused model with no reasoning,
# low verbosity, and a tight output cap. Keep the existing model for mail drafting.
p = root / 'app' / 'OpenAIClient.swift'
s = p.read_text()

old_call = '''        performRequest(\n            apiKey: apiKey,\n            instructions: systemInstructions,\n            input: "EMAIL THREAD:\\n\\(String(mailText.prefix(30_000)))"\n        ) { result in'''
new_call = '''        performRequest(\n            apiKey: apiKey,\n            instructions: systemInstructions,\n            input: "EMAIL THREAD:\\n\\(String(mailText.prefix(30_000)))",\n            model: "gpt-5.4-nano",\n            reasoningEffort: "none",\n            maxOutputTokens: 320,\n            lowVerbosity: true\n        ) { result in'''
if old_call not in s:
    raise SystemExit('calendar performRequest call not found')
s = s.replace(old_call, new_call, 1)

old_sig = '''    private func performRequest(\n        apiKey: String,\n        instructions: String,\n        input: String,\n        completion: @escaping (Result<String, Error>) -> Void\n    ) {'''
new_sig = '''    private func performRequest(\n        apiKey: String,\n        instructions: String,\n        input: String,\n        model: String = "gpt-5-mini",\n        reasoningEffort: String? = nil,\n        maxOutputTokens: Int? = nil,\n        lowVerbosity: Bool = false,\n        completion: @escaping (Result<String, Error>) -> Void\n    ) {'''
if old_sig not in s:
    raise SystemExit('performRequest signature not found')
s = s.replace(old_sig, new_sig, 1)

old_payload = '''        let payload: [String: Any] = [\n            "model": "gpt-5-mini",\n            "store": false,\n            "instructions": instructions,\n            "input": input\n        ]'''
new_payload = '''        var payload: [String: Any] = [\n            "model": model,\n            "store": false,\n            "instructions": instructions,\n            "input": input\n        ]\n        if let reasoningEffort {\n            payload["reasoning"] = ["effort": reasoningEffort]\n        }\n        if let maxOutputTokens {\n            payload["max_output_tokens"] = maxOutputTokens\n        }\n        if lowVerbosity {\n            payload["text"] = ["verbosity": "low"]\n        }'''
if old_payload not in s:
    raise SystemExit('payload block not found')
s = s.replace(old_payload, new_payload, 1)
p.write_text(s)

# 2) Floating panel should behave like Outlook UI context, not a permanent always-on-top window.
p = root / 'app' / 'FloatingPanelController.swift'
s = p.read_text()

old_props = '''    private var resizeWorkItem: DispatchWorkItem?\n    var onClose: (() -> Void)?'''
new_props = '''    private var resizeWorkItem: DispatchWorkItem?\n    private var workspaceActivationObserver: NSObjectProtocol?\n    private var wantsVisibleInOutlookContext = false\n    var onClose: (() -> Void)?'''
if old_props not in s:
    raise SystemExit('panel properties anchor not found')
s = s.replace(old_props, new_props, 1)

old_init_tail = '''        panel.delegate = self\n        observeLayoutState()\n    }'''
new_init_tail = '''        panel.delegate = self\n        observeLayoutState()\n        observeWorkspaceContext()\n    }'''
if old_init_tail not in s:
    raise SystemExit('panel init tail not found')
s = s.replace(old_init_tail, new_init_tail, 1)

old_showhide = '''    func show(activate: Bool = true) {\n        resizeForCurrentState(animated: false)\n        panel.orderFrontRegardless()\n\n        if activate {\n            panel.makeKey()\n            NSApp.activate(ignoringOtherApps: true)\n        }\n    }\n\n    func hide() {\n        panel.orderOut(nil)\n    }'''
new_showhide = '''    func show(activate: Bool = true) {\n        wantsVisibleInOutlookContext = true\n        resizeForCurrentState(animated: false)\n        panel.orderFrontRegardless()\n\n        if activate {\n            panel.makeKey()\n            NSApp.activate(ignoringOtherApps: true)\n        }\n    }\n\n    func hide() {\n        wantsVisibleInOutlookContext = false\n        panel.orderOut(nil)\n    }\n\n    private func hideForExternalApp() {\n        panel.orderOut(nil)\n    }\n\n    private func restoreForOutlookIfNeeded() {\n        guard wantsVisibleInOutlookContext else { return }\n        resizeForCurrentState(animated: false)\n        panel.orderFrontRegardless()\n    }'''
if old_showhide not in s:
    raise SystemExit('show/hide block not found')
s = s.replace(old_showhide, new_showhide, 1)

insert_anchor = '''    private func observeLayoutState() {'''
context_method = '''    private func observeWorkspaceContext() {\n        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(\n            forName: NSWorkspace.didActivateApplicationNotification,\n            object: nil,\n            queue: .main\n        ) { [weak self] notification in\n            guard let self,\n                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }\n\n            let bundleID = app.bundleIdentifier ?? ""\n            if bundleID == "com.microsoft.Outlook" {\n                self.restoreForOutlookIfNeeded()\n                return\n            }\n\n            // Replyzen itself is allowed to stay visible while the user types in the panel.\n            if bundleID == Bundle.main.bundleIdentifier {\n                return\n            }\n\n            // Any other foreground app (browser, Finder, Slack, etc.) hides the panel,\n            // but remembers that it should return when Outlook becomes active again.\n            if self.panel.isVisible {\n                self.hideForExternalApp()\n            }\n        }\n    }\n\n    deinit {\n        if let workspaceActivationObserver {\n            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)\n        }\n    }\n\n'''
if insert_anchor not in s:
    raise SystemExit('observeLayoutState anchor not found')
s = s.replace(insert_anchor, context_method + insert_anchor, 1)
p.write_text(s)

# 3) Version bump.
p = root / 'app' / 'Info.plist'
s = p.read_text()
s = s.replace('<string>1.13.0</string>', '<string>1.14.0</string>', 1)
s = s.replace('<string>14</string>', '<string>15</string>', 1)
p.write_text(s)

# 4) Update package/notes.
p = root / 'Build-CI.sh'
s = p.read_text()
s = s.replace('Replyzen-update-1.13.zip', 'Replyzen-update-1.14.zip')
s = s.replace('Replyzen 1.13: Termine verwenden standardmäßig immer die Zeitzone Europe/Berlin (CET/CEST), unabhängig von der aktuellen Mac-Zeitzone.',
              'Replyzen 1.14: schnellere Terminextraktion mit einem kleinen Extraction-Modell; Replyzen schwebt nur im Outlook-Kontext und verschwindet bei Wechsel zu anderen Apps.')
p.write_text(s)
