# Folio COL-10 Copy content — implementation report

Source checkout: `/Users/philip.scholl/_WORK/markdown-reader`, branch `codex/collaboration-first-stage`. No commits made. Existing `.superpowers/` and concurrent `experiments/` work were not edited.

## Changes

- `web/editing.js`: `setupEditing` now returns a controller with requestContent/cleanup; read mode returns untouched source; rendered mode runs its existing serializer/commit then posts contentReady. Commit returns false on protected-node rejection. Composition defers snapshot delivery until the next turn after compositionend/final input. Open complex modal or inline link draft produces actionable contentFailed. Cleanup invalidates deferred requests and removes composition listeners.
- `web/reader.js`: exposes `window.Folio.requestContent`, cancels the previous controller before replacing its DOM, and installs the new controller on render.
- `ReaderModel.swift`: injected Bool pasteboard writer defaults to clearing NSPasteboard.general and setString(.string). Each request captures UUID/document/source-or-rendered/editing mode/token/native-editor identity, checks every acknowledgment against current state and accepted model.text, and invalidates before clipboard writes. Missing editor, failed dispatch, synchronization mismatch, cancellation and 15-second timeout fail visibly. Source reads the actual NSTextView and waits for post-change/next-main-loop completion when marked text exists. Empty strings skip the writer; whitespace is copied exactly. Successful write alone publishes Copied for 1.5s and requests an accessibility announcement.
- `MarkdownEditor.swift`: the representable update path distinguishes mode/document entry from unrelated model notifications; preserves newer native strings and marked text, selection and undo for Copy status changes. Source coordinator supplies the post-change callback. Dismantle cancels via editor removal.
- `ReaderWebView.swift`: forwards contentReady/contentFailed; teardown and process termination invalidate pending requests.
- `ReaderView.swift`: trailing primary-action `Button("Copy content")`; label stays unchanged, disabled for loading/print/pending, separate Copied text using existing accent.
- New native and JS controller tests; reader.js regenerated only by `npm run bundle`.

No change to Copy Formatted Text, code-copy, Export Feedback, parser semantics, source normalization, file save, or edit-history contracts.

## Automated evidence

- TDD: 5 new JS controller tests first failed because setupEditing had no requestContent; after implementation all passed. Native new API tests failed compilation for absent Copy API; after implementation focused native tests ran. A specific additional source-entry regression was observed as an assertion failure (hidden old source remained after rendered edits), then corrected and verified green. Undo regression fixture initially lacked a native undo manager; a test-only NSTextView subclass supplies a real UndoManager. WK setup initially returned unsupported JavaScript function/bridge results; adding explicit void results corrected test plumbing without weakening assertions.
- `npm test`: **53 tests passed, 0 failures**. Full suite log `/private/tmp/folio-copy-npm.log`.
- `npm run bundle`: **passed**, generated Resources/reader.js. Bundler also reproduces its ordinary other resources, with no tracked differences to those files.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`: **61 native tests passed, 0 failures** (43 ReaderCore + 18 MarkdownReader, including 14 CopyContent tests). Full suite log `/private/tmp/folio-copy-swift.log`. No warnings/errors in this final run.
- Initial bare `swift test` failed before tests because the selected CommandLineTools SDK could not import XCTest; installed Xcode SDK was used via per-command DEVELOPER_DIR, without changing global xcode-select.
- `git diff --check` excluding generated Resources/reader.js: passed. Generated minified bundle reports trailing whitespace inside bundled dependency/template literal content; it was not hand-edited. Bundled identifier renaming causes a large generated diff; authored implementation remains localized to the named files.

Native tests verify exact CRLF/front matter/authored comments/code/task markers, current source newer than model, whole content despite selection, clipboard false/empty/whitespace behavior, dirty/baseline/snapshot/file bytes unchanged, representable guard and undo, actual AppKit marked-text deferral/post-change, source entry, source teardown/document/mode/token cancellation, late/duplicate acknowledgments, and real 15-second timeout preserving marked text.

Real WKWebView integration uses the freshly generated full bundle and actual ReaderWebView.Coordinator message handler, with injected clipboard writer. It proves editDocument precedes contentReady; fresh unsaved rendered DOM serializes with protected code/task bytes retained; untouched Read-mode source is exact; synthetic composition waits for final input; open complex Apply modal rejects Copy; matching UUID/token snapshots with wrong text fail; document/mode/token/termination invalidation rejects late snapshots; evaluated-JS dispatch failure produces no clipboard write. These are real WKWebView runtime tests, not static serializer inference.

JS DOM fixture tests run the actual setupEditing controller and serializeDocument through events and verify pending DOM flush/order, Read source exactness, composition final input, protected-node no-success rejection, open link draft rejection, and cleanup cancellation.

## Acceptance limits — explicitly unrun

Actual user-driven Folio UI acceptance remains unrun. Parent reports CUA initialization blocked by host sandbox parsing of the `[PP]` workspace path; no alternate UI-automation route was attempted. The following still require manual acceptance: both themes, narrow/normal window toolbar visibility/overflow, keyboard and VoiceOver reachability/announcement, selection and scrolling in a long/code-heavy document, actual checkbox interaction, real IME input in both editors, plain-text target paste comparison, and unchanged formatted-selection copy/failure retry in a visible app. Synthetic CompositionEvent/AppKit marked-text tests do not establish actual IME candidate-window behavior. No deployment/release/signing claims are made.

The complete change is ready for independent review. Do not claim product/IME/UI acceptance complete from the automated evidence alone.
