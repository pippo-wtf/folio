# Six development issues — verification

Candidate: Folio 0.14.0, build 2026100616. Regular Folio and Folio Staging are installed at their existing personal Applications paths. This report separates implemented/verified behavior from public distribution approval.

## Corrections

- Invisible sidebar thumbs no longer intercept clicks after fading out.
- Source identity uses exact UTF-8 comparison. Canonically equivalent Unicode can contain different bytes: native/rendered editing, dirty detection, undo/redo, reload, copy, task actions, shared-save callbacks and the agent journal now preserve that distinction. Regression tests demonstrated a newer normalization-only draft being overwritten before the fix.
- Narrow panes no longer inherit a minimum 72px gutter from generated layout. At a 360px document width, usable text grows from 216px to 288px; contextual Edit controls remain on screen. Wide typography/settings are unchanged.

## Fresh automated evidence

- Full native suite: 255 tests, zero failures, one focus-only skip. Command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-system native --scratch-path /private/tmp/folio-public-release-tests`.
- Renderer suite: 58/58 tests pass (`npm test`).
- New coverage: `SidebarScrollIndicatorTests`, `ComplexEditingAcceptanceTests`, `UnicodeSourceIdentityTests`, `NarrowLayoutAcceptanceTests`, plus copy, shared-task and journal regressions.
- The normal-motion test explicitly pins Reduce Motion off; a separate test enables it, independent of CI host preferences.
- Sidebar tests render the actual AppKit indicator: 3px neutral thumb, 5px inset, 700ms idle delay, 200ms fade, reduced-motion immediate hide, no thumb on short lists, no invisible hit target.
- Complex editing tests use WKWebView: code/language, links, images, table cells and row/column operations; cancel, independent undo/redo, exact unrelated source preservation, disk save/reopen, labels and unsafe-input rejection.
- Unicode regressions were run failing before correction and passing afterward. Copy uses a real WKWebView and native editor synchronization uses NSTextView. Shared-save race coverage confirms a newer draft remains intact.
- Independent production-diff review reported no actionable findings. Both release-channel builds and deep strict signature verification passed.

## Native app checks

Only disposable Markdown files were edited. In regular Folio, keyboard paste changed a code block from `42` to `43`; Apply/Save wrote `43`, Undo/Save wrote `42`, Redo/Save wrote `43`. Reopening retained the saved value. A mouse-selected passage accepted a private comment; both highlight and exact comment survived normal quit, replacement and relaunch. The Marked sidebar entry retained its comment and keyboard jump.

A 60-heading Contents list was scrolled and navigated with the keyboard. Public (dark) and Staging (light) active/idle screenshots show the custom thumb and its disappearance, without a native track. A separate disposable document contains 30 seeded saved marks for long-list navigation testing; these fixtures are not presented as user-created comments. With native sidebar focus, Down moved selection from mark 06 to 07 and scrolled the document to the selected passage. Narrow-window screenshots verify the corrected title wrapping and gutters at 580×520 including the sidebar. The formatting strip remains horizontally scrollable through its last action (WKWebView assertion).

Screenshots in the adjacent `six-issues` directory use only disposable text.

## Existing evidence retained

- Issue #2: signed isolated updater build 990001 → 990002 installed/relaunched; Later fetched no ZIP, ready-state Cancel retained the old app, and unsaved-draft Cancel during 990002 → 990003 retained both app and draft. Offline error and tampered signature rejection were recorded in `docs/DEVELOPMENT-TICKETS.md`. Fresh configuration tests and installed plist inspection confirm distinct signed HTTPS feeds and automatic download/install disabled. The published 0.13.8 feeds were fetched and matched their recorded hashes. This is not a claim that the pending 0.14 release is live.
- Issue #4: prior native feedback export replayed six exact events; source hashes matched disk, saved marks/comments survived reopening, and Clear-before-export/Cancel protected history. New byte-identity regressions close the normalization gap.
- Issue #5: the earlier disposable process recovery test reopened a separate recovered copy and preserved the original file. The recorded 1MB/10,753-heading parser benchmark improved from about 4,536ms to 191ms; this is a parser benchmark, not whole-app latency.

## Open release and manual checks

Issue #6 remains open. Apple submissions for build 2026100616: app `097089d4-11f0-4025-8e01-3b6edc16a573`, DMG `c1f5983d-ee44-4cb6-b7c8-377cff371166`; both Accepted, stapled and validated on 7 October 2026. Older 2026100614 submissions were superseded and cannot approve this build. Keychain credentials work in the elevated release context; restricted-context credential errors were not evidence of missing credentials.

Public preview release: app, DMG, installer helper and nested payload were accepted by Gatekeeper as Notarized Developer ID. The nested executable matches the final app. Three Sparkle signatures were verified, and three tampered copies were rejected. Exact artifact hashes and source bindings are recorded in `updates/release-0.14.0.json`. The installer targets the receiving user’s ~/Applications and asks about default Markdown handling. A clean-Mac install is not yet verified; do not claim a stable-release acceptance from same-machine checks.

VoiceOver and input-method composition need manual native verification. One focus-only CSS test is skipped because its test host cannot acquire document focus. Full two-Mac OneDrive recovery acceptance remains pending, as already disclosed in the collaboration guide. These are explicit limits, not silent passing checks.
