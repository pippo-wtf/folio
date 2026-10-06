# Independent Task 4 renderer review — 2026-10-06

Current verdict: APPROVE the reviewed renderer slice after narrow re-review; both initial P2 findings below are resolved. See the dated follow-up section. No product files changed by this reviewer.

Reviewed `web/shared-review.js`, narrow `web/reader.js` integration, `tests-js/collaboration.test.mjs`, `Tests/MarkdownReaderTests/CollaborationRendererTests.swift`, generated `Sources/MarkdownReader/Resources/reader.js`, and approved plan Task 4. No broader source/UI review.

## P2 — Resume deferred painting when the inline link field closes

`web/shared-review.js:28,53-58,67` detects `#format-bar input` as a deferred state, but observes only the document root. The toolbar is appended to body outside that root. A refresh while its Link field is open clears existing shared ranges and returns `deferred`. Escape removes the field without document mutation; no refresh is scheduled afterward, so highlights remain invisible until another editor mutation or native refresh/navigation.

Reproduced with the generated bundle in actual WKWebView, using the real toolbar button and real Escape handler:
1. Render `Original.` with editing enabled and select its text.
2. Open `#format-bar [data-link]`.
3. `Folio.updateSharedReview('current',[record])` -> `painting: deferred`, located [0,8), registry size 0.
4. Dispatch Escape to the link input; after 150ms input is absent but registry size remains 0.

Fix: observe the relevant toolbar lifecycle or expose an explicit editor-state completion hook that schedules refresh when the deferral ends. Add a real WK regression asserting repaint after cancel without another review update or content mutation.

## P2 — Reject UUID duplicates after canonicalization

`web/shared-review.js:30-31,43` checks duplicate IDs as case-sensitive strings, then lowercases them for the CSS Highlight registry. UUID validation explicitly accepts either case. Thus uppercase/lowercase spellings of the same UUID both return `located`, but the second silently replaces the first CSS range. Internal click ranges can also retain both spellings, creating inconsistent identity/count behavior.

Actual WK reproduction: refresh with record ID `AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA` and an otherwise identical record with its lowercased ID. Both return located/painted while registry size is 1. With different valid quotes, one visual range would shadow the other. Canonicalize IDs before duplicate detection and reject all records sharing the canonical ID. Preserve separate distinct overlapping UUIDs. Native UUID serialization may avoid this in ordinary current traffic, but the exposed renderer boundary accepts the conflicting inputs and promises duplicate rejection.

## Verified and bounded evidence

- `npm test`: independently reran, 56 passed, 0 failures.
- In-memory esbuild using the exact bundle options produces byte-identical generated reader.js; no bundle file was rewritten.
- Standalone native WK probe: `/private/tmp/folio-renderer-review-probe.swift`, compiled binary `/private/tmp/folio-renderer-review-probe`. Run with AppKit main event loop, current generated renderer, nonpersistent WK store. It reproduces both findings and confirms full render clears shared CSS ranges/styles and old token refresh is rejected.
- Focused Swift suite rerun attempted with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path /private/tmp/folio-renderer-review-build --filter CollaborationRendererTests`. Build failed before tests during concurrent source work: CollaborationCoordinator.swift:245/325 could not find SharedSourceComparison; associated key-path inference error at 276. This is a verification blocker outside renderer scope, not a renderer regression finding. Previous implementer five-test pass was not independently repeated.
- Code inspection supports rendered UTF-16 node boundary mapping, exact quote/context matching through existing locate, no incoming document DOM/private serializer changes, independent distinct-ID overlaps, mutation/input/composition cleanup, and unsupported-paint navigation fallback. Existing WK tests cover DOM/selection/private marks/native undo/fallback. No claim that inspection alone is runtime proof.
- Missing/ambiguous anchors fail closed and stale token reset independently observed in probe. Exact same-string duplicate detection is present; canonical duplicate gap is above.
- No real IME, human UI/light-dark/narrow-width/VoiceOver, two-Mac delivery, minimum macOS engine, or full native-suite acceptance claimed.

No scope expansion after confirmed bounded findings. Re-review the two fixes and their regression tests, bundle provenance, and focused renderer tests when concurrent compilation is stable.


## Narrow re-review — both P2 fixes and approved preview/mode hooks

Verdict: **Approve this renderer slice. No remaining actionable finding in the re-review scope.** This supersedes the original request-changes verdict; the original repro details remain above as historical evidence.

Scope: both reported P2 fixes; `locateSharedReview` nonpainting preview; explicitly authorized Private/Shared toolbar routing in `web/highlights.js`; matching regression tests and generated bundle. No broader application source-save, UI, or native bridge acceptance review.

Independent checks on the frozen final renderer:

- Re-ran the unchanged original `/private/tmp/folio-renderer-review-probe` against the new generated bundle. Real Link field + deferred update + Escape now restores registry size **1** without another update or document edit. Case-variant duplicate UUIDs both return **invalid**, registry size **0**. Render still clears ranges/style and rejects the old token.
- Inspected `/private/tmp/folio-renderer-fixes-probe.swift`, independently compiled it with full Xcode into `/private/tmp/folio-renderer-rereview-probe`, then ran it. **13/13 actual WK checks passed.** The probe verifies repaint recovery, canonical duplicate rejection, preview location [10,16) with unchanged DOM/selection/active Highlight identity and no callback, stale preview rejection, explicit Shared mode, distinct Highlight/Comment intent, no saveHighlights/commentHighlight callbacks, retained selection, stale mode rejection, Private save after switching back, and Private reset after render.
- `npm test`: **57 passed, 0 failed**.
- Exact in-memory esbuild output equals generated reader.js. Final SHA-256 `e9eab8e146cf8c4b6470679051e3ca820993e6118fd5eb7eca93592e09705626` matches the implementer freeze report.
- Focused handwritten renderer/test `git diff --check`: passed.
- Code review confirms every shared toolbar path returns before private mutation; private Remove is both hidden and refused in Shared mode, private-mark click actions are suppressed in Shared mode, and normal Private save behavior remains intact. Preview is a read-only call to the same batch matcher and does not replace active records/ranges, paint, or send sidebar status.
- Parent reports the final nine renderer native tests passed in the current public-native run. That broader integrated rerun is parent evidence, not independently rerun here; the earlier compile-blocked attempt remains historical above. The independently rebuilt WK probe gives fresh renderer-level runtime evidence.

No real IME, human theme/narrow-width/accessibility review, two-Mac delivery, minimum-macOS compatibility, full app bridge behavior, or source-save acceptance is inferred. No further renderer changes requested.
