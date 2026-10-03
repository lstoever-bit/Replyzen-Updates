# ReplyZen: native Outlook mail-core rewrite

Separate development candidate, not a published fix. source-current, its manifest and the production update feed remain unchanged.

## Fundamental change
Reply, Reply All, Forward and New Mail use one native Outlook object-model transport. No Accessibility focus search, foreground PID guard, synthetic shortcut, coordinate click, clipboard transfer, fallback chain or Send command in this core.

1. Capture the selected original as a native Outlook message ID and local identity snapshot.
2. Generate with the existing AI client/editor. Pin source identity while generation is in flight.
3. Ask Outlook to create the appropriate native draft.
4. Read that draft and prepend the note to its content, preserving native thread, recipients and attachments.
5. Read back the same message ID; verify note, original, subject and attachment inventory. Open the draft for manual inspection/sending.

No replay after uncertain mutation timeouts. Empty subjects do not discard a valid body.

## Compatibility / scope
Targets classic/Legacy Outlook for Mac with AppleScript support, not universal New Outlook support. Unsupported commands and denied Automation permission are explicit errors; there is no fallback to broken GUI automation.

The existing UI, AI client, keychain service, subject generation and calendar module are reused. Six old Reply helper files are excluded from the built candidate. Accessibility remains in existing toolbar/calendar features, not mail insertion. Preview uses a separate bundle ID, no production updater and no automatically registered login item.

## Build / verification
`python3 rewrite/assemble.py` builds .native-build from a hash-checked 1.75 baseline; it never edits source-current.

`rewrite/validate.sh` tests the transaction/composition and real Apple-event descriptor bridge, compiles the static script against the dictionary from a signature-checked official Microsoft installer, and compiles the full macOS app. A mock transport is not an authenticated Outlook mailbox.

## Release gates
CI does not upload an ad-hoc-signed app for the user to battle Gatekeeper again. rewrite/sign-release.sh requires an installed Developer ID Application identity and notarytool keychain profile, notarizes, staples and runs Gatekeeper assessment. No quarantine stripping or Gatekeeper disabling.

Live acceptance still required: Reply/Reply All, New Mail, Forward with zero/one/multiple files, duplicate filenames, inline images, formatting, account behavior, source changed during generation, and permission denial. Dictionary compilation and mock tests do not prove those end-to-end cases.

## Privacy
No mail, account, headers, clipboard or secret logging. Identity snapshot remains in memory and is not sent in the AI prompt. User values are Apple-event data, never script-source interpolation. No send command.

See the read-only Native Outlook Rebuild workflow and acceptance.json for exact evidence and outstanding gates. The Microsoft installer/dictionary are validation inputs, not redistributed source dependencies.
