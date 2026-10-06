# Final collaboration integration review — final

**Final verdict: APPROVE the reviewed code integration after the narrow rename and refresh-barrier fixes. No remaining actionable blocker was found in this bounded whole-branch review. This is not actual-app visual, provider, two-Mac, or release acceptance.**

Initial verdict was REQUEST CHANGES for one reproduced P2 lifecycle integration blocker, now closed below. No product source edits, subagents, network, or shared-provider operations were performed. Review root `/Users/philip.scholl/_WORK/markdown-reader`, baseline `dc64d87` to the frozen current working tree.

## P2 — Renamed document cannot recover shared context through the UI

Primary location: `Sources/MarkdownReader/Collaboration/CollaborationCoordinator.swift:100–104`, with `open` at lines 172–178, path reconciliation at lines 115–126, and `apply` at 593–606. UI dependency: `SharedFolderSheet.swift:66–81` offers only `coordinator.candidates` to reconnect a document.

Reproduction in a disposable ordinary local folder:

1. Create a workspace and register `a.md`.
2. Rename that same file, preserving its filesystem identity, to `moved.md`.
3. Refresh the coordinator. Its document list stays at `a.md`; the new candidate inventory is not emitted.
4. Choose Open for the registered UUID. SharedWorkspaceStore correctly finds `moved.md` through its unique resource identity, but the replica retains `a.md`.
5. Perform the same source read and selection used by ReaderModel. `currentDocument` is nil, so the shared-review sidebar and guarded-save path are unavailable for the successfully opened moved file.

The replica reports `needsReconnection` for the missing old path. `scan` returns before `access.inventory()` or resource-identity resolution, preserving stale candidate paths along with the old review. The UI's reconnect picker therefore cannot offer `moved.md`. Open changes only the workspace access binding and then invokes the same blocked scan. Even if scanning is allowed to continue, comparing the current relative path against `ref` after `access.document()` has already updated that ref misses the stale replica binding.

Keep incomplete review state protected, but allow bounded identity/inventory recovery to reach the actual reconnect UI, and synchronize both local bindings after a uniquely verified move. Never infer identity from matching content. Cover the actual coordinator rename → refresh → open → shared selection → guarded save path and an ambiguous move/copy case.

Independent runtime evidence: `/private/tmp/folio-final-integration-probes/Tests/ReviewTests/IntegrationBoundaryTests.swift`, `testRenamedDocumentCanSaveAfterExplicitOpen`. Log `/private/tmp/folio-final-integration-probes.log`, 2026-10-06 16:39:02. The native package uses fresh unchanged ReaderCore and coordinator/monitor files, extracted actual source-comparison value types, and a small BuildChannel stub. Two assertions fail: registered path remains `a.md`; selected moved document has no shared reference. A corrected probe waits for in-flight scans and normalizes `/tmp` aliases. It does not reach the subsequent guarded save because shared selection is already nil.

## Checks and bounded conclusions

- Read the approved integration plan and final foundation, workspace, renderer, save/lifecycle, and native review-UI reports. Previously resolved slice defects were not reopened.
- Traced real menu/sidebar/native bridge routes for Shared selection, private/shared mode, comments/replies, thread state, tasks, save/leave/quit, source comparison/recovery, document open, local unread state, and version-2 export. No additional concrete integration blocker established in this pass.
- Public gate excludes both ordinary public and update-test channels; disabled coordinator has no worker or watcher. Current view/menu entry points use that gate.
- The private-copy case-alias destination concern was tested and did NOT reproduce: it rejected the destination and created no file inside the shared folder. Do not treat it as a finding.
- Independently inspected completed parent-run native logs: public 200/200 and Staging 200/200. Parent reports JavaScript 57/57. These full suites do not contain the reproduced rename boundary.
- A broad `git diff --check dc64d87` reports trailing whitespace in generated bundled reader.js; this is generated/vendor content, not elevated to an integration blocker or rewritten by review.
- Source saving is available only after the user enables the separate disposable-pilot toggle. Ambiguous/deleted task anchors remain safely blocked; the guide explicitly states that existing task identity reattachment is not implemented.
- The user guide and acceptance ledger do not claim actual-app or two-Mac acceptance. All two-Mac acceptance rows remain NOT RUN, which is accurate. The app-automation/path-selection blocker and any final build metadata still belong in the final operator evidence; this reviewer did not perform a visual walkthrough.

This is code-path and local runtime integration review. No actual signed UI, real IME/accessibility/light-dark/narrow-window acceptance, OneDrive convergence, Files On-Demand fault behavior, real simultaneous two-Mac recovery, or 200/1000/2000-event visible UI latency was established. The 28-test schema-1 experiment and full native suites do not substitute for those gates. Claude/Pippo final architecture/frontend review remains separate.

## Frozen-fix recheck — blocker closed, 2026-10-06 16:46:44

The unchanged original two independent native probes pass: **2 tests, 0 failures, 0 skips**. Log `/private/tmp/folio-final-integration-recheck.log`. Renamed source now updates the displayed path, opens/selects the same shared identity, and successfully performs the guarded save. The private case-alias destination remains rejected.

Only the frozen changed coordinator was copied into the independent scratch package; the original probe source is unchanged (SHA-256 `ed340cd8483736b3b3e07951e98d84fea8c229fd4ff30d85dc7c7866060eb6eb`). Reviewed final coordinator SHA-256: `51663510404f1844db134512f4e8aaf3866ca7e3498681dce785cf7a474609b1`.

Narrow source review confirms verified resource-based local binding resolution runs before publication; the helper compares the workspace binding against the replica binding, updates the latter, checks the resulting source URL, and restores the previous access binding on rejection. Open uses the same helper. In `needsReconnection`, current document/candidate metadata can refresh while previous accepted review state and events stay retained; copied matching text does not establish identity.

Also inspected the owner's permanent native regressions and completed green log `/private/tmp/folio-coordinator-rename-green.log`: unique rename → open → select → save, plus missing original/same-content copy → retained review → fresh reconnect choices → explicit reconnect. Both pass (2/2). Owner's broader focused and controller's full post-fix checks remain separately owned; this review does not relabel the earlier 200-test pre-fix results as post-fix results.

No further broad review pass or speculative scope expansion was performed. Final build/signing/operator ledger and required actual two-Mac acceptance remain parent-owned. The original finding and reproduction above are historical evidence, not a remaining defect.

## Follow-up refresh barrier review — approved, 2026-10-06 16:53:46

The parent’s post-rename full run exposed a separate refresh-await race: when another scan was active, awaited `refresh()` returned before the requested rescan reached MainActor state. The unchanged late-source-branch assertion therefore observed stale source heads. This supersedes any interpretation that the initial broad native green results cover the final fixes.

Reviewed only the new coordinator waiters array, `refresh()` coalescing/defer change, and added overlapping-caller regression. No product files were edited by this reviewer. MainActor serializes registration and draining of waiters; each owning refresh exits through defer on success, scan failure, or generation mismatch, resets refreshing/busy ownership, clears the queue, and resumes each continuation once. The worker does not await MainActor refresh, so this change introduces no demonstrated cyclic wait. Task cancellation does not cancel an uninterruptible provider read; the waiter completes when the scan drains, consistent with the existing worker contract. Callers that own document/workspace operations retain their existing generation checks.

Fresh independent native runtime probes passed **5/5, 0 failures, 0 skips**: both original rename/case-alias probes plus overlapping awaited refresh completion, a cancelled waiter overlapping Stop watching, and failed scan releasing overlapping waiters. New probe `/private/tmp/folio-final-integration-probes/Tests/ReviewTests/RefreshBarrierReviewTests.swift`; log `/private/tmp/folio-final-refresh-barrier-recheck.log`. Completion-sensitive probes have bounded 5-second XCTest timeouts. The original two-probe source was not changed.

Final reviewed coordinator SHA-256: `2689da51da88ea5d9b2a8783ea695c4be2b13e7b164146d70467b6a883aff495`. Owner provided a concrete RED log for the overlapping refresh regression and reports 40 focused passes; controller owns the final full public/Staging reruns. No remaining actionable blocker found in this narrow follow-up. The final code-integration approval stands; actual-app visual/provider/two-Mac acceptance remains separate and unverified.
