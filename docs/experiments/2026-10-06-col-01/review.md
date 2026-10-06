# COL-01 independent review

Status: NO REMAINING BLOCKERS FOUND after correction and independent re-review at 11:58 on 2026-10-06. The four original runtime-confirmed findings below are resolved. No repository files edited by reviewer.

Approved references read: docs/superpowers/plans/2026-10-06-collaboration-feasibility.md and docs/superpowers/specs/2026-10-06-collaboration-design.md.

## Original confirmed blockers — all resolved

1. **P1 — Recovery is disabled precisely when the source disappears.** `experiments/CollaborationTransport/Sources/TransportProbe/SourceRecovery.swift:70` calls the publication/action `permit` gate. Deleting the registered fixture changes reconciliation to `needsReconnection`, translated to `identityConflict`, so `recover` refuses to export already durable base/proposed bytes. A missing shared workspace similarly prevents the local archive from loading. Recovery needs a bounded local-evidence path independent of source/transport availability; it should retain honest incomplete-history status. Reproduced by preparing S0→S1, removing fixture.md, and requesting recovery: throws identityConflict.

2. **P1 — Superseded preparations can overwrite an explicitly resolved source.** `SourceRecovery.swift:37` checks only that at most one source head exists; it never checks that this prepared proposal is still eligible. Prepare S0→S1; enqueue an explicit resolution superseding that proposal and choosing S0; apply the old proposal. The write succeeds and changes the source to S1 while the only source head still claims S0. Require the applied proposal to be a current accepted head, or create a new causally valid explicit operation before changing source. Reproduced with real local NSFileCoordinator execution in the scratch package.

3. **P1 — Observed external versions bypass aggregate storage limits.** `SourceRecovery.swift:48-49` persists each failed-compare version under ready/<proposal>/observed; `ReplicaStore.swift:88-91` skips those files during snapshot and total-byte admission. With snapshot limit 2 already used by base/proposed, three different failed applies retain three more snapshots and reconciliation still reports complete. Repeated retries therefore grow retained recovery history beyond the advertised limit until the unrelated candidate bound trips. The recovery export check at `SourceRecovery.swift:82` also checks each observed file against base+proposed, not a running total. Account for distinct observed snapshots and cumulative bytes before writing, without deleting existing evidence.

4. **P2 — Candidate budget is per directory rather than per reconciliation.** `ReplicaStore.swift:78` separately gives the full candidate allowance to shared, received, ready, and conflicts. With candidates=4, an initialized store containing one enqueued/published comment scans more than four physical candidates but reports complete. Use one shared bounded scan budget across all sources and return capacityExceeded without a complete partial state when exhausted. The plan expressly specifies 5,000 candidate files per scan and whole-reconciliation capacity handling.

## Evidence

Reproductions: `/private/tmp/folio-sync-review-package/Tests/TransportProbeTests/ReviewTests.swift`.

Command (temporary copy only):

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer CLANG_MODULE_CACHE_PATH=/private/tmp/folio-sync-review-clang SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/folio-sync-review-modules swift test --package-path /private/tmp/folio-sync-review-package --disable-sandbox --filter ReviewTests`

Run with approved escalation so macOS file coordination was available: **4 tests executed, 5 assertion failures**, 2026-10-06 11:56:27. Initial sandbox-only attempt was insufficient evidence for coordinated source writes and was not used as the final reproduction.

The export-evidence implementation was actively being repaired during this review and is intentionally not duplicated as a new finding. The final source re-review also inspected the export coverage fix and found no additional blocker in it.

Real two-Mac OneDrive testing: **NOT RUN**. These are local deterministic regression checks, not provider delivery/durability evidence. COL-02–09 acceptance remains blocked by the actual two-Mac gate.

## Final re-review evidence

Fresh implementation source copied into the scratch package and read again. Independent tests: **5 passed, 0 failures**, 2026-10-06 11:58:19, using the same escalated command above. Checks covered:

- Recovery after deleting the registered source.
- Recovery with the entire shared root moved/unavailable; exact base/proposed bytes retained and publication still blocked.
- Applying an old proposal after explicit resolution is rejected and source bytes remain unchanged.
- Observed external snapshot admission refuses capacity overflow before storing new evidence and leaves external bytes unchanged.
- Combined shared/local candidate count exceeding the cap produces capacityExceeded.

The observed-capacity regression was adjusted for the corrected pre-write behavior: it now verifies rejection before excess evidence exists, rather than expecting a later reconciliation to discover stored overflow. This preserves the tested invariant. The scan-cap test stages with normal limits then uses a constrained reader so setup/publication does not stop earlier than the actual scan assertion.

This is a bounded code review and local regression result, not final architecture/product approval or evidence of actual OneDrive behavior. Full package/root test execution remains owned by the implementation/integration workers.
