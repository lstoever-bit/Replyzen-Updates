# ReplyZen developer handover

## Source of truth

- Repository: lstoever-bit/Replyzen-Updates.
- Current editable source: `source-current/app/` (Swift/AppKit/SwiftUI).
- This release: **1.43.0, build 44**, based on 1.42.0, build 43.
- The live updater reads the root `update.json`; do not treat old screenshots or the highest `vNN` folder as the released app version.
- `vNN/` and split base64 archives are historical migration inputs, not canonical source.

## Compatibility

Keep the existing bundle identifier `com.lstoever.replyzen`, executable `Replyzen`, app archive layout `Replyzen.app`, keychain service names, login item and update feed unchanged. The user-visible brand is `ReplyZen`. macOS 13+, arm64 target remains unchanged from 1.42. No API-key or calendar-token migration is required by this change.

## 1.43 changes

- Central cached logo and menu-bar template image; visible heading and main labels use ReplyZen.
- Toolbar pauses its geometry timer while Outlook is not the foreground application or the overlay is suppressed. Workspace notifications restart it; observers and timers are released on stop.
- Avoid redundant window moves and front-order operations.
- Share the four identical JSON normalizers without changing prompt/model choices, formats or errors.
- Prepare PDF upload bodies off the main thread and reserve their capacity.
- Whole-module optimized build; one icon resize per distinct resolution.
- Canonical source/resources retained after a successful build. The one-time migration is version- and source-hash-checked and idempotent.

## Verification and publishing

`bash tests/run-tests.sh source-current` exercises decoder/error cases, JSON normalization, off-main-thread file preparation, source compatibility contracts and shell syntax. `bash source-current/Build-CI.sh` builds and code-signs the native app on macOS. `python3 tests/verify_update.py source-current` verifies the archive and manifest. The workflow publishes the ZIP and root manifest together only on main, after all checks succeed. Branch builds cannot change the live update feed.

No live mailbox, payment, calendar or paid API calls are made by these tests. Real Outlook UI interactions still need a smoke test on the user's Mac: Reply, Reply All, New, Forward, Calendar, Payment, app switching, full screen and Outlook quit/reopen. No measured CPU or latency improvement is claimed.
