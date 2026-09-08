# ReplyZen interface localization

Version 1.47.0 (build 48) adds an app-wide interface preference: US English (`en-US`), German (`de`), and Spanish (`es`). German remains the default for existing installations.

## User controls

Open Settings from the menu-bar icon, or use the gear icon in the workspace. The App language picker saves immediately. SwiftUI views, AppKit menu items, and Outlook-toolbar accessibility labels/tooltips refresh without discarding the current draft. Email output language is a separate existing control and is not changed by this preference.

## Canonical source

`source-current/app/Resources/Localization.json` is the runtime catalog. Every app-owned key has exactly three translations. Numbered `{0}` placeholders may move between translations, but must not be added, dropped or duplicated. `tests/test_localization_catalog.py` checks this and audits unlocalized UI labels.

`LocalizationCore.swift` provides:
- `L10n.tr(key, values...)` for presentation strings.
- `L10n.source(key, values...)` for canonical String-backed status/error values in the existing model. This preserves control-flow comparisons independently of locale.
- `L10n.render(message)` at display boundaries, retaining message provenance for live switching. The bounded in-memory diagnostic registry is not persisted.
- `L10n.diagnostic(value)` for explicitly nested app errors. Ordinary interpolation arguments, including names, filenames, IBANs and user values, are never translated.

`AppLocalization.swift` persists the interface preference under `ReplyZen.InterfaceLanguage`, publishes changes to SwiftUI and notifies native menus/toolbars. The root environment supplies the selected locale to date/time controls. The event timezone remains Europe/Berlin.

Do not localize bundle IDs, keychain keys, update endpoints, AppleScript/accessibility matching strings, API prompt instructions, or user-authored/generated content. Do not use a locale-dependent `.id` on the editor: it would recreate its state and lose selection/undo history.

## Native and external text

All text controlled by ReplyZen is localized. macOS-owned permission dialogs and native system menus are controlled by macOS. The per-app AppleLanguages preference is updated for subsequent launches; no global system or Outlook setting is changed. Raw diagnostics returned by an external provider remain verbatim so that error codes and troubleshooting details are preserved.

## Release checks

The workflow builds directly from canonical `source-current`, not a chain of historical patches. Run the existing regression/typography tests plus `tests/run-localization-tests.sh`. Localization checks cover catalog completeness, placeholders, saved preference reload, safe interpolation, and the native editor in three languages, light/dark mode, minimum/default sizes, reply/new/forward and preview. Live-switch tests verify that the draft text, HTML and chosen email language stay unchanged. No real OpenAI requests, Outlook messages or calendar writes are made by these tests.

The build packages Localization.json and localized release notes; updater verification checks the packaged resource, binary identity, version/build and SHA-256. A test-branch build does not publish a user update. Only the successful main build publishes the ZIP and root update.json used by the app.
