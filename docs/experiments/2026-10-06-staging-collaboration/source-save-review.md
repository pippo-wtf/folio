# Task 5 independent source/lifecycle review

Final verdict after fixes: no remaining blocking findings in this bounded Task 5 re-review. Original review requested changes; all findings below are now closed.

Original review context: Source root `/Users/philip.scholl/_WORK/markdown-reader`; reviewed frozen Task 5 against approved plan and report. No product source changes, actual user documents, cloud pilot access, or subagents. Tests added only to copied package `/private/tmp/folio-save-review-src`.

## Findings

1. **P1 — A rendered draft/composition can be discarded before leave confirmation.** `Sources/MarkdownReader/ReaderModel.swift:349–357` synchronizes only NSTextView, then allows leaving when `model.dirty` is false. WKWebView may hold buffered content or active IME composition absent from `model.text`. Actual `newDocument()` replaces that buffer; actual AppDelegate quit returns `.terminateNow`. A shared-document rendered acknowledgement must precede the clean/dirty decision for new/open/welcome/quit, with cancellation/timeouts retaining the current document. Review the post-save guard at ReaderModel ~434 too: it reads `self.text` in rendered mode, so it cannot prove no newer buffered DOM/marked draft appeared during background saving. The initial save handshake alone does not prove the end-of-save buffer is current.

   Runtime RED: `testReviewRenderedBufferedDraftBlocksLeave` and `testReviewRenderedCompositionBlocksQuit`, copied `CollaborationSaveTests.swift` lines 188–225. Both failed (3 assertions); newDocument fileURL became nil/title Untitled; quit returned rawValue 1 (terminateNow). Log `/private/tmp/folio-save-review-tests.log`. These use the same real WKWebView setup as the existing passing buffered-save test.

2. **P2 — Staging Save on an untitled document has no destination-selection path.** `ReaderModel.swift:377–380` routes Save to the old synchronous save when there is no fileURL and source access has been verified. `save()` at ~501 rejects any enabled-coordinator call where fileURL/snapshot is nil. Calling requestSharedSave without asCopy also falls back to this same rejecting path (~392). This affects an ordinary untitled Staging document even without a selected collaboration workspace. Route an untitled Save (including Save during leave) through the guarded absent-destination copy/register flow. Public coordinator-disabled behavior is unchanged. This is a direct call-path finding; no modal interaction was claimed.

3. **P2 — A partially delivered proposal prevents exporting otherwise available recovery evidence.** `CollaborationCoordinator.swift:306–310` checks only the proposed snapshot before calling `CollaborationSourceRecovery.recover`, which requires both base and proposed snapshots. When proposed bytes arrive before the base, export throws immediately, leaving no coverage.json and skipping local observations and later proposals. Export available bytes independently and report missing base/proposed hashes, while continuing other recoverable heads. Do not report complete recovery.

   Runtime RED: `testReviewExportWithPendingMissingBaseStillExportsAvailableEvidence`, copied `CollaborationSaveTests.swift` ~270. A valid remote proposal and its proposed snapshot were delivered into a disposable local fixture; base intentionally absent. Export threw `invalid("proposal snapshots pending/unavailable")` and coverage.json was absent (2 failed assertions). Log `/private/tmp/folio-save-review-export-tests.log`.

## Verification and scope limits

Both test runs used full Xcode native Swift tests and independent scratch path `/private/tmp/folio-save-review-build`; initial sandbox cache failure was rerun with approved escalation. Built complete copied current source and ran three new targeted tests, all RED for the findings above. Existing implementation owner reports 16 focused Task5 passes; this review did not repeat the full suite. Other UI-owner RED regressions are outside this Task5 report.

Reviewed: verified local source bindings before guarded writes; same serial worker for provider I/O; durable base/proposal preparation before exact-byte apply; intent vs local receipt labels; conservative combined candidate/byte admission; explicit new-copy registration; preservation of draft on failure; all-head resolution flow. No additional blocking finding established in those paths during this bounded review.

No real UI appearance, signed provider panel, Files On-Demand, real OneDrive receipt, two-Mac recovery, physical wake/relaunch, or public-release acceptance claimed. Those remain NOT RUN/required later.

## Narrow re-review, 2026-10-06 16:31

The three original findings are fixed in the inspected source. Independent isolated native run `/private/tmp/folio-save-review-rereview.log` passed all 23 implementation-owner Task5 tests, including original reviewer regressions, new rendered new/open/welcome/quit save continuations, second save acknowledgement/newer DOM preservation, untitled Save destination routing, and partial export exact bytes + missing hash coverage.

One directly related remaining **P1** in `ReaderModel.reloadSharedSource` (~502–523): after its initial editor acknowledgement it awaits file read and evidence retention, then checks `model.text` for rendered mode before replacing/rendering incoming text. A newer buffered DOM draft entered during that I/O is absent from model.text and gets replaced. Independent native regression `testReviewReloadSecondAcknowledgementPreservesNewerDOM` failed three assertions: old baseline became incoming, newer draft missing from model, dirty false. Exact test `/private/tmp/folio-save-review-src/Tests/MarkdownReaderTests/CollaborationSaveTests.swift` ~365. Source owner received it. Apply the same second editor acknowledgement as the fixed save path before journal transition/render. This was checked because the follow-up explicitly included new reload provenance lines; no unrelated areas were expanded.

Status: original three issues cleared; reload draft preservation fix/recheck pending. No full-suite or provider acceptance claims added.

## Final re-review — findings closed, 2026-10-06 16:32

The follow-up reload fix now requests a second actual editor snapshot after read/evidence retention, and performs the same-document / equal-source / clean-draft checks inside that acknowledgement before journaling/rendering. Native marked text and rendered composition retain the existing handshake cancellation/deferral behavior. No replacement occurs when a newer rendered draft has arrived.

Independent verification: `/private/tmp/folio-save-review-reload-green.log`, **3/3 tests passed**, native build exit 0. Tests: buffered native draft before reload; own proved local task bytes with `.renderedEdit` journal attribution; newly reproduced newer buffered rendered DOM during reload. This follows the prior independent **23/23 existing Task5 tests passing** in the 24-test run that exposed only the now-fixed reload regression. Implementation owner also ran final **24/24 Task5 tests passing** (`/private/tmp/folio-task5-review-final.log`), inspected as supporting evidence.

Final reviewed outcomes:
- Rendered leave/quit acknowledges actual content before clean/dirty decisions; continuations resume only after completion.
- Save acknowledges actual content again after worker I/O, preserving newer drafts/composition.
- Untitled Staging Save reaches guarded new-destination creation.
- Partial source export retains delivered exact bytes and local observations with missing snapshot hashes and `complete=false`.
- Reload acknowledges actual content again after I/O; proved own bytes can retain local journal provenance, while ordinary incoming versions remain external reloads.

All original findings and the directly related reload finding are closed. No additional blocking finding established in this narrow re-review. No actual provider/two-Mac acceptance, full integrated final suite, release, or UI appearance claims are made. Product files were changed only by the implementation owner; reviewer test copies remained in `/private/tmp`.

Final freeze delta checked: sole difference from independently tested ReaderModel copy is explicit `Task { [self] in }` capture in reload (no behavioral change). Owner final focused log `/private/tmp/folio-task5-review-final-focused.log` passes **8/8** tests after this diagnostic cleanup.
