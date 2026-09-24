# Folio everyday-use sprint

Goal: edit confidently on the page, carry precise feedback to agents, and prepare user-controlled updates.

Existing public release remains 0.12.3 until the new release checks pass.

## Execution

Three parallel implementation agents use GPT-6 Sol with high reasoning: updater, visual editing, and edit journal. These involve native integration or source-preservation correctness, so a smaller model would create unnecessary review risk. Root integrates, verifies the actual app and owns the sidebar. Independent review uses Sol/high after implementation capacity frees. No permanent background model cost is added to Folio.

## 1. [Match sidebar scrolling to the document](https://github.com/pippo-wtf/folio/issues/1)

Owner: Root integration; native UI validation

Status: In progress.

- [ ] Sidebar uses the document indicator width, neutral colour and right inset; native duplicate/track is absent.
- [ ] Indicator appears while scrolling and fades after 700 ms with a 200 ms fade; reduced-motion preference is respected.
- [ ] Long Contents and Marked lists retain keyboard navigation and jump actions; short lists show no thumb.
- [ ] Public and Staging build; active and idle states visually checked in the installed app.

Native evidence (2026-09-24): the sidebar thumb responded to dragging, appeared and faded with scrolling, and retained keyboard navigation. The remaining visual, reduced-motion and package-specific checks above stay open.

## 2. [Offer signed updates with release notes and an explicit Update action](https://github.com/pippo-wtf/folio/issues/2)

Owner: GPT-6 Sol / high reasoning; native updater and signing integration

Status: In progress.

- [x] Automatic checks can report a newer version and show release notes; checks never automatically download or install.
- [x] Check for Updates is available; Update initiates a verified download/install/relaunch; Later leaves current app unchanged.
- [x] Unsaved work is protected by save/discard/cancel before termination.
- [x] Public and Staging use distinct HTTPS feeds and identities; invalid/missing signing configuration fails closed.
- [ ] A signed older-to-newer update, failure path and cancellation are verified before declaring release-ready.

Recorded test-flavor updater evidence (2026-09-24): a signed build `990001` updated to `990002` and relaunched. Choosing **Later** on `990001` left it installed and downloaded no ZIP. During an offered `990002` → `990003` update, **Cancel** with an unsaved document kept `990002` running and preserved the draft. Strict update-signature verification passed. An unavailable feed showed a recoverable update error. Original feed/archive/notes signatures passed and three tampered copies were rejected. Live published-feed verification remains open.

## 3. [Edit tables, code, links and images on the rendered page](https://github.com/pippo-wtf/folio/issues/3)

Owner: GPT-6 Sol / high reasoning; source-preserving editor implementation

Status: In progress.

- [x] Code text and language, link label/destination, image alt/path, and table cells can be edited using contextual controls.
- [x] Table rows/columns can be added or removed where supported; unsupported syntax remains available via Source.
- [x] Cancel leaves Markdown unchanged; applied edits participate in undo/redo and preserve unrelated source bytes.
- [x] No unsafe HTML/URLs or malformed input can bypass renderer safety; keyboard controls have useful labels.
- [x] Focused automated tests and native app smoke cover representative edit/save/reopen flows.

Native evidence (2026-09-24): code, table and local-image edits were applied, saved and reopened in a disposable document. The edited values persisted and an untouched source sentinel stayed byte-identical. Cancel preserved the code source, and undoing a later table edit left an earlier code edit intact. Straight ASCII quotes survived typing in the code field. In test build 991005, the final simplified shortcut path passed Undo/Redo using the German keyboard's physical Y mapping for Command-Z. The word counter stayed at 53 before the code dialog, after Cancel and after Apply for the tested code change. The 44 JavaScript renderer tests passed. Link label and destination edits also passed native Apply/save/source verification. Input-method composition and VoiceOver still need native checks.

## 4. [Include precise text changes in local agent feedback](https://github.com/pippo-wtf/folio/issues/4)

Owner: GPT-6 Sol / high reasoning; durable journal and replay correctness

Status: In progress.

- [x] Feedback distinguishes text edits, attention-only highlights and explicit comments.
- [x] Each recorded replacement contains exact before/after text, explicitly labelled offsets, version hashes, identity and time.
- [x] Source/rendered edits and undo/redo are represented; external reloads are not mislabelled as human edits.
- [x] History survives relaunch, handles Unicode/CRLF, is bounded and atomically persisted; corrupt/full storage reports an actionable error.
- [x] Export stays explicit and local; existing highlights migrate safely; replay tests prove exact reconstruction and reject stale hashes.

Automated evidence (2026-09-24): eight `EditJournalStoreTests` pass for UTF-8 offsets, Unicode and CRLF, insert/delete, undo/redo, replay and stale-hash rejection, coalescing, persistence across store instances, Save As isolation, explicit closed-file gaps, corruption and size/event limits. The app target compiled with the integrated journal. Native feedback export produced six events whose exact replay and UTF-8 version hashes were verified against the saved Markdown file. Saved highlights and comments survived reopening. Native Clear before export was blocked with an actionable message; after export it showed Clear/Cancel, and Cancel preserved the history. Destructive clear itself has not been exercised in the app.

## 5. [Verify everyday editing and recovery reliability](https://github.com/pippo-wtf/folio/issues/5)

Owner: Root integration; then independent GPT-6 Sol / high review

Status: In progress.

- [x] Core and renderer suites pass on combined changes; source preservation, conflicting saves and recovery corruption have meaningful coverage.
- [ ] Keyboard, paste, undo/redo, narrow window, saved marks/comments and complex block controls are smoke-tested without changing private documents.
- [x] Large-document behaviour is measured and limitations recorded; recovery is verified using a disposable document/process.
- [x] All unresolved accessibility, input-method, hardware or manual checks are explicitly tracked; no unsupported general-release claim.

Automated evidence (2026-09-24): after removing the temporary recovery trace, `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path /private/tmp/folio-recovery-investigation` exited 0, **39 Swift tests passed, 0 failed**. This includes source preservation, conflicting saves, bounded recovery reads and failed-write preservation. The JavaScript renderer suite passed **44/44** after the editing changes. Native save/reopen and sidebar checks above passed on disposable content; the full combined checklist remains open.

Performance evidence: a 1 MB fixture containing 10,753 headings improved from approximately 4,536 ms to 191 ms in the parser/editing benchmark after replacing repeated heading-ID searches. This is a parser benchmark, not an end-to-end app latency claim.

Native recovery evidence (2026-09-24): a disposable source edit was saved to the sandbox recovery file, the exact app process was killed, and test build 991005 displayed the Recover/Discard dialog on relaunch. Choosing Recover opened a separate recovered copy containing `RECOVERY THIRD SENTINEL`; clicking Save used Save As to create `Recovered-QA.md`, while the original Markdown file remained unchanged. A prior launch trace identified the cause: an aborted modal response had been treated as Discard. Startup now waits for app activation and only the explicit Discard response clears the draft. The full ticket remains open for narrow-window, VoiceOver, input-method and other manual checks.

## 6. [Prepare signed, notarized public distribution](https://github.com/pippo-wtf/folio/issues/6)

Owner: Root release integration; GPT-6 Sol / medium review when slot available

Status: In progress.

- [x] Developer ID signing covers app, extensions and updater helpers with correct entitlements/hardened runtime.
- [ ] Notarization and stapling succeed; Gatekeeper verification and clean-Mac installation are recorded before stable release.
- [x] Public installer excludes admin layout/presets; Staging retains them with isolated data and no Markdown association.
- [ ] Release, update feed and Homebrew checksum agree; existing release assets are never silently overwritten.
- [ ] Exactly the stable Folio and Folio Staging install names remain; no secrets/certificates are committed.

Signing evidence (2026-09-24): Developer ID signing, Apple notarization, stapling, strict signature validation and Gatekeeper acceptance passed for public and staging candidates and the public DMG. The final journal-warning fix passed the 39-test Swift suite and an app build. Rebuilt public/staging apps and DMG passed notarization, stapling, strict codesign and Gatekeeper again; `updates/release-0.13.0.json` records exact final artifact hashes, notarization IDs and ReaderModel source hash. Both channels accepted their valid feed/archive/notes signatures and rejected three tampered variants each. Clean-Mac installation and publication remain pending.

## Remaining release checks

The launch-recovery data-loss blocker was resolved and verified in disposable test build 991005. The earlier zero-valid-certificate blocker is resolved. The final candidate must match its manifest and pass clean-Mac installation before publication. VoiceOver, input-method composition, reduced-motion UI and narrow-window checks remain explicitly unverified. Final review also found a transient journal-failure warning could disappear after a later successful save; its correction now preserves/reasserts the actionable warning without blocking saves. The 39-test suite and app build passed again, and rebuilt release artifacts passed Apple notarization and local signature checks. No installation or publication was performed. Existing public release stays at 0.12.3.

## 7. Install for the current user and offer the Markdown default

- [x] The installer resolves the receiving user's `~/Applications` at runtime; no shared Applications shortcut or build-machine home path.
- [x] Signed Folio payload is embedded in the installer, so macOS translocation cannot break sibling-file lookup.
- [x] Source and copied signatures are checked before replacement; running Folio and a personal Applications symlink outside the home are rejected; failed replacement restores the prior app or preserves its backup.
- [x] First public launch offers Make Default / Not Now; no association change on decline; the Folio menu can reopen the choice. Staging and update-test do not offer it.
- [x] App and installer compile; 42 Swift tests pass, including isolated personal-folder install/replacement, failed-copy verification preserving the installed app, and running-app/external-folder rejection.
- [x] Native default prompt displays Make Default / Not Now; declining persists the choice in an isolated test runner without changing file associations.
- [x] Final signed helper launched from the mounted DMG, displayed `/Users/philip.scholl/Applications`, and Cancel exited without replacement. Helper and outer DMG passed notarization, stapling and Gatekeeper.
- [ ] Full signed installation and default-association acceptance are verified on a clean Mac before public replacement.

The installer is a separate non-sandboxed app inside the DMG, used only to copy the signed app into the user's home. It installs no persistent helper. Sparkle updates use a separate app-only ZIP. The existing public download and installed apps remain unchanged.
