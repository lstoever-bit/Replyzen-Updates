from pathlib import Path
import sys

root = Path(sys.argv[1])


def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f"{label} not found")
    return text.replace(old, new, 1)

# Outlook overlay: exactly New, Reply, Reply All, Forward, Cancel.
p = root / "app" / "OutlookToolbarButtonController.swift"
s = p.read_text()
s = must_replace(
    s,
    '''    private let newButton: NSButton\n    private let replyButton: NSButton\n    private let declineButton: NSButton\n''',
    '''    private let newButton: NSButton\n    private let replyButton: NSButton\n    private let replyAllButton: NSButton\n    private let forwardButton: NSButton\n    private let cancelButton: NSButton\n''',
    "toolbar button declarations",
)
s = must_replace(
    s,
    '''    var newAction: (() -> Void)?\n    var replyAction: (() -> Void)?\n    var declineAction: (() -> Void)?\n''',
    '''    var newAction: (() -> Void)?\n    var replyAction: (() -> Void)?\n    var replyAllAction: (() -> Void)?\n    var forwardAction: (() -> Void)?\n    var cancelAction: (() -> Void)?\n''',
    "toolbar actions",
)
s = must_replace(s, '        let size = NSSize(width: 250, height: 34)\n', '        let size = NSSize(width: 448, height: 34)\n', "toolbar size")
s = must_replace(
    s,
    '''        newButton = makeButton(title: "New", symbol: "square.and.pencil", x: 4, width: 72, help: "Neue Mail mit Replyzen")\n        replyButton = makeButton(title: "Reply", symbol: "arrowshape.turn.up.left.fill", x: 84, width: 76, help: "Auf die aktuelle Mail antworten")\n        declineButton = makeButton(title: "Decline", symbol: "xmark.circle", x: 168, width: 78, help: "Freundliche kurze Absage direkt als Antwort einsetzen")\n\n        effect.addSubview(newButton)\n        effect.addSubview(replyButton)\n        effect.addSubview(declineButton)\n''',
    '''        newButton = makeButton(title: "New", symbol: "square.and.pencil", x: 4, width: 68, help: "Neue Mail mit Replyzen")\n        replyButton = makeButton(title: "Reply", symbol: "arrowshape.turn.up.left", x: 76, width: 74, help: "Nur dem Absender antworten")\n        replyAllButton = makeButton(title: "Reply All", symbol: "arrowshape.turn.up.left.2", x: 154, width: 94, help: "Allen Empfängern antworten")\n        forwardButton = makeButton(title: "Forward", symbol: "arrowshape.turn.up.right", x: 252, width: 88, help: "Aktuelle Mail in Outlook weiterleiten")\n        cancelButton = makeButton(title: "Cancel", symbol: "xmark.circle", x: 344, width: 96, help: "Freundliche kurze Absage direkt als Antwort einsetzen")\n\n        effect.addSubview(newButton)\n        effect.addSubview(replyButton)\n        effect.addSubview(replyAllButton)\n        effect.addSubview(forwardButton)\n        effect.addSubview(cancelButton)\n''',
    "toolbar button setup",
)
s = must_replace(
    s,
    '''        newButton.target = self\n        newButton.action = #selector(newClicked)\n        replyButton.target = self\n        replyButton.action = #selector(replyClicked)\n        declineButton.target = self\n        declineButton.action = #selector(declineClicked)\n''',
    '''        newButton.target = self\n        newButton.action = #selector(newClicked)\n        replyButton.target = self\n        replyButton.action = #selector(replyClicked)\n        replyAllButton.target = self\n        replyAllButton.action = #selector(replyAllClicked)\n        forwardButton.target = self\n        forwardButton.action = #selector(forwardClicked)\n        cancelButton.target = self\n        cancelButton.action = #selector(cancelClicked)\n''',
    "toolbar target setup",
)
s = must_replace(
    s,
    '''    @objc private func newClicked() { newAction?() }\n    @objc private func replyClicked() { replyAction?() }\n    @objc private func declineClicked() { declineAction?() }\n''',
    '''    @objc private func newClicked() { newAction?() }\n    @objc private func replyClicked() { replyAction?() }\n    @objc private func replyAllClicked() { replyAllAction?() }\n    @objc private func forwardClicked() { forwardAction?() }\n    @objc private func cancelClicked() { cancelAction?() }\n''',
    "toolbar selectors",
)
p.write_text(s)

# Keyboard shortcut for Forward in Outlook for Mac: Command+J.
p = root / "app" / "KeyboardController.swift"
s = p.read_text()
s = must_replace(
    s,
    '''    func sendCommandN() {\n        sendKey(code: 45, flags: .maskCommand)\n    }\n''',
    '''    func sendCommandN() {\n        sendKey(code: 45, flags: .maskCommand)\n    }\n\n    func sendCommandJ() {\n        sendKey(code: 38, flags: .maskCommand)\n    }\n''',
    "keyboard forward shortcut",
)
p.write_text(s)

# AppDelegate: distinguish Reply and Reply All from the overlay. Generic Replyzen
# reply remains Reply All by default, preserving the previous behavior.
p = root / "app" / "AppDelegate.swift"
s = p.read_text()
s = must_replace(
    s,
    '    private var requestedMailMode: AppState.OutputMode?\n',
    '    private var requestedMailMode: AppState.OutputMode?\n    private var replyAllForCurrentDraft = true\n',
    "reply all state",
)
s = must_replace(
    s,
    '''    private func configureToolbarButton() {\n        toolbarButton.newAction = { [weak self] in self?.openNewMailWorkspace() }\n        toolbarButton.replyAction = { [weak self] in self?.openReplyWorkspace() }\n        toolbarButton.declineAction = { [weak self] in self?.quickDecline() }\n        toolbarButton.start()\n    }\n\n    private func openNewMailWorkspace() {\n        requestedMailMode = .newMail\n        openWorkspace()\n    }\n\n    private func openReplyWorkspace() {\n        requestedMailMode = .reply\n        openWorkspace()\n    }\n''',
    '''    private func configureToolbarButton() {\n        toolbarButton.newAction = { [weak self] in self?.openNewMailWorkspace() }\n        toolbarButton.replyAction = { [weak self] in self?.openReplyWorkspace(replyAll: false) }\n        toolbarButton.replyAllAction = { [weak self] in self?.openReplyWorkspace(replyAll: true) }\n        toolbarButton.forwardAction = { [weak self] in self?.forwardCurrentMail() }\n        toolbarButton.cancelAction = { [weak self] in self?.quickDecline() }\n        toolbarButton.start()\n    }\n\n    private func openNewMailWorkspace() {\n        requestedMailMode = .newMail\n        replyAllForCurrentDraft = true\n        openWorkspace()\n    }\n\n    private func openReplyWorkspace(replyAll: Bool) {\n        requestedMailMode = .reply\n        replyAllForCurrentDraft = replyAll\n        openWorkspace()\n    }\n\n    private func forwardCurrentMail() {\n        guard !isRunningFlow else { return }\n        guard let pid = outlook.runningPID() else { return }\n        guard outlook.isTrusted() else {\n            outlook.requestTrustPrompt()\n            return\n        }\n\n        toolbarButton.setSuppressed(true)\n        outlook.activateOutlook(pid: pid)\n        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in\n            self?.keyboard.sendCommandJ()\n            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {\n                self?.toolbarButton.setSuppressed(false)\n            }\n        }\n    }\n''',
    "toolbar app actions",
)
s = must_replace(
    s,
    '''        // One unified Mail form. New and Reply only choose the behavior of the\n        // same form. The Outlook overlay can request either mode explicitly.\n        if requestedMailMode == .reply {\n''',
    '''        // One unified Mail form. New and Reply only choose the behavior of the\n        // same form. The Outlook overlay can request either mode explicitly.\n        // When Reply is entered through the generic Replyzen window, keep the\n        // historical default of Reply All. The explicit overlay buttons override it.\n        if requestedMailMode != .reply {\n            replyAllForCurrentDraft = true\n        }\n        if requestedMailMode == .reply {\n''',
    "generic reply all default",
)
s = must_replace(
    s,
    '''        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in\n            self?.keyboard.sendCommandShiftR()\n\n            DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in\n''',
    '''        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in\n            guard let self else { return }\n            if self.replyAllForCurrentDraft {\n                self.keyboard.sendCommandShiftR()\n            } else {\n                self.keyboard.sendCommandR()\n            }\n\n            DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in\n''',
    "reply shortcut choice",
)
p.write_text(s)

# Version and release metadata.
p = root / "app" / "Info.plist"
s = p.read_text()
s = s.replace('<string>1.31.0</string>', '<string>1.32.0</string>', 1)
s = s.replace('<string>32</string>', '<string>33</string>', 1)
p.write_text(s)

p = root / "Build-CI.sh"
s = p.read_text()
s = s.replace('Replyzen-update-1.31.zip', 'Replyzen-update-1.32.zip')
s = s.replace(
    'Replyzen 1.31: FollowUpThen Reminder verwendet kompakte fut.io Formate ohne Doppelpunkt, z. B. tues1100@fut.io. 06:00 ist Standard; bei 06:00 wird die Uhrzeit weggelassen, z. B. tues@fut.io. Das Zeit Dropdown startet bei 06:00.',
    'Replyzen 1.32: Das Outlook Overlay zeigt jetzt genau New, Reply, Reply All, Forward und Cancel. Reply antwortet nur dem Absender, Reply All allen Empfängern, Forward öffnet direkt Outlook Weiterleiten und Cancel erstellt weiterhin eine kurze freundliche Absage. Der normale Replyzen Reply bleibt standardmäßig Reply All.'
)
p.write_text(s)
