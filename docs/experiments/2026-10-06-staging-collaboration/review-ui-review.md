# Independent native shared-review review — Tasks 4/6/7

Final verdict after frozen-fix recheck: APPROVE within the reviewed Task 4/6/7 native UI scope. Both reproduced P2 findings below are resolved. No implementation files changed by reviewer.

Reviewed frozen files: SharedReviewController.swift, SharedReviewSidebar.swift, ReaderModel+SharedReview.swift, CollaborationCoordinator+Review.swift, ReaderWebView shared bridge changes, and Review/Task/Activity native tests against the approved 2026-10-06 staging-collaboration plan and /private/tmp/folio-review-ui-report.md. Source owner work and independently reviewed renderer excluded except read-only integration tracing.

## Findings

1. **[P2] A successful send leaves its draft behind after switching discussions.** `Sources/MarkdownReader/Collaboration/ReaderModel+SharedReview.swift:94–95`, with controller draft persistence at `SharedReviewController.swift:13–15`. Send a comment in A, then click B's quote while the async save is pending (quote controls remain enabled). The controller saves A's composing text to its draft map. Once A's event is durable, the completion returns because B is selected, so it never acknowledges/clears A's stored submitted draft. Returning to A restores the already-sent text; pressing Enter creates another immutable comment. Scratch native test confirms one durable message plus restored text `This is submitted` instead of an empty draft. Acknowledge the captured draft/reply in its originating thread even when that thread is inactive, while preserving any newer draft.

2. **[P2] Changing editing mode unlocks an unfinished comment send and allows duplicates.** `Sources/MarkdownReader/Collaboration/SharedReviewController.swift:34`, with `ReaderModel+SharedReview.swift:84–95`. Start a send, then change editingEnabled. The actual ReaderModel setter calls render, rotates reviewRenderToken, and bind clears busy despite the comment submission still running. Send becomes available with the original draft; a second Send creates a second event. Scratch native test invokes that actual mode setter, verifies busy is false and observes two durable shared messages instead of one. Renderer token invalidation must be separate from ownership of a durable comment operation. Also ensure an older completion cannot clear a newer operation's busy state.

## Runtime evidence

Disposable source copy: `/private/tmp/folio-ui-independent-review`; regression file: `/private/tmp/folio-ui-independent-review/Tests/MarkdownReaderTests/CollaborationUIIndependentReviewTests.swift`.

Command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path /private/tmp/folio-ui-independent-review --build-system native -Xswiftc -DFOLIO_STAGING --filter CollaborationUIIndependentReviewTests --scratch-path /private/tmp/folio-review-native`

Final log: `/private/tmp/folio-ui-independent-review.log`. Build succeeded. Two tests executed, three expected regression assertion failures, zero unexpected failures, 1.727 seconds. These tests use real fixture coordinators/stores and actual ReaderModel actions, no production mocks. Unrelated native test files were excluded only in the disposable copy after a first compile hit concurrent source-owner saveDestination API mismatch. Initial sandbox compiler cache access failed; approved escalated rerun compiled successfully.

## Other scoped checks

- Shared feedback/export does not pass private marks, journals or read state; preserves original events via core export. Mark read persists exact observed IDs locally and does not resolve work.
- Explicit private-mark sharing previews selected current marks/comments, creates new shared IDs, preserves originals, and checks saved raw revision. No silent private-store sharing found.
- Annotation reattachment uses selected saved revision, document/token callback checks, all observed anchor heads, and retains discussion identity. Shared task states stay independent of discussion resolution.
- Task source application checks editor snapshot, saved baseline bytes, unique task anchor, and the single current task head before guarded save. Known source-owner authored reload fix remains separately owned; not duplicated as a finding here.
- Accepted task-identity ambiguity limitation remains: no task reattachment protocol. UI should retain the documented blocked status; this review does not reopen architecture scope.
- A dirty-midbatch private-preview early return appeared to leave busy set, but no normal user-reachable edit route through its modal sheet was demonstrated. Not elevated as a finding.

No real app visual/IME/VoiceOver/light-dark/narrow-window or two-Mac transport/source-recovery acceptance was performed. No performance claim for 200/1,000/2,000-event visible UI. No full-suite success claimed. The existing ten-test green handoff does not cover the two reproduced interaction sequences above.


## Frozen-fix recheck — final approval

Rechecked only the two original P2 findings, using the unchanged original independent scratch probes against a fresh copy of the frozen Sources. Both tests now PASS: 2 tests, 0 failures, 1.428 seconds; build completed successfully. Log: `/private/tmp/folio-ui-independent-recheck.log`.

- `testSuccessfulCommentClearsInactiveThreadDraft`: the real durable message remains single and returning to its inactive discussion now yields an empty submitted draft.
- `testEditingModeChangeKeepsPendingCommentBusy`: the actual editingEnabled setter/render rotation preserves busy while the send is unfinished; second submit is refused and only one message is durable.

Code inspection confirms per-operation pendingCommentID ownership survives renderer token changes and rejects abandoned-document completion; acknowledgement matches captured text plus reply target before clearing either selected or inactive draft. No residual blocker found in this bounded recheck. Implementer's focused 13-test green log was inspected; the independent recheck itself ran only the original two probes. Other source-owner changes and actual-app/two-Mac acceptance remain under their separate reviewers/gates.
