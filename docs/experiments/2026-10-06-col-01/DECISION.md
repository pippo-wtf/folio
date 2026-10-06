# COL-01 acceptance ledger

Date: 2026-10-06. Scope: isolated transport feasibility experiment only. Candidate option: A, immutable review events and raw source recovery in a shared folder. Format/limits are provisional and require Claude/Pippo review.

**Actual two-Mac OneDrive gate: NOT RUN.** Pippo confirms a second Mac is available; actual OneDrive account/folder type, shared permissions, operators and provider behavior have not been verified. Local simulations do not authorize COL-02–09 or a collaboration release.

| Scenario | Local simulation | Real two-Mac |
|---|---|---|
| 100 actions/device; exact 200-ID convergence; repeated reversed delivery; restart | PASS | NOT RUN |
| Concurrent Done/Reopen, explicit full/partial resolution, causal cycles and missing parents | PASS | NOT RUN |
| Event identity variants; conflicting manifests; copied/renamed registrations | PASS | NOT RUN |
| Bounded file reads and byte/count/diagnostic/candidate limits | PASS | NOT RUN |
| Offline SA/SB from S0; event-before-snapshot pending; both complete versions recovered | PASS | NOT RUN |
| Source full-byte compare despite same size/date; failed save retains intended/observed bytes | PASS | NOT RUN |
| Process-interruption preparation/ready/write/publication windows | PASS | NOT RUN |
| CLI prepare → persisted UUID → apply → event-only → snapshot-only; interrupted retry | PASS | NOT RUN |
| Cloud-only/hydration, pause/reconnect, permission loss, provider conflict-copy naming | NOT RUN | NOT RUN |
| Measured 200/1,000/2,000-event processing, remote latency, growth/retention qualification | NOT RUN | NOT RUN |
| Filesystem power-loss persistence and directory fsync barriers | NOT RUN | NOT RUN |
| Product editor, watched-folder UI, private stores, profiles, anchors and security bookmarks | OUT OF SCOPE | OUT OF SCOPE |

Final local validation: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path experiments/CollaborationTransport` passed **28 tests, zero failures** (13.995 seconds); `swift build --package-path experiments/CollaborationTransport` with the same toolchain passed (exit 0). Independent Astra review reproduced four blockers, then separately verified their fixes in **five passing scratch tests**; see [review.md](review.md). Run commands and RED→GREEN records are in the worker handoff `/private/tmp/folio-sync-implementation.md`. Tests create disposable temporary roots; no runtime fixtures, OneDrive credentials, or personal documents belong in source.

The protocol uses exact-byte SHA-256 including BOM/line endings; canonical UUID identities; schema 1; durable separate local outbox; causal heads; explicit all-head supersession; bounded diagnostics and fail-closed capacity outcomes. Concurrent same-baseline first saves branch without requiring a shared source-parent event. Source proposals record intended recoverable bytes, separate from local save receipts. Received actors/IDs remain original and are never written into Folio's private journals.

Known limits: synchronous provider reads can hang; simulated unavailable items do not prove Files On-Demand behavior. Local file flush/atomic rename/hard-link creation do not establish cloud transactions, real provider compatibility or power-loss durability. Recovery retains observed external compare-conflict bytes but cannot reconstruct never-observed edits; `externalRecoveryGap` remains explicit. Rename/copy reconnect is deliberate. Whole reconciliation counts candidates across shared, received, outbox and conflict trees; duplicate physical artifacts can reach the scan bound before the distinct-event cap. Observed source evidence participates in snapshot/byte admission and recovery output is bounded. Offline/deleted-source recovery uses retained local evidence while scan status remains unavailable/stale and new actions are refused. Bounds and export coverage must be inspected before using an export as complete evidence. The CLI supports one disposable source; task/source-resolution fixtures use the library harness.

Real pilot checklist before a scope decision:

- Record both macOS/OneDrive versions, actual Personal/Business/shared account-folder type, sharing setup, permissions, offline availability, Files On-Demand state, provider limits and selected pilot paths.
- Follow the README's staged A/B commands with a fresh disposable shared subfolder. Compare exact origin/received ID ledgers and independent derived states.
- Recover exact S0/SA/SB on each Mac after OneDrive's visible Markdown winner, delayed/missing snapshots and interrupted retry.
- Record every duplicate/copy/rename, task conflict, unavailable/cloud-only, permission-loss and restart scenario with exact artifact IDs and PASS/FAIL/NOT RUN.
- Measure local monotonic processing separately from origin-to-remote receipt with clock uncertainty; list timeouts/non-deliveries. Target ≤2 seconds local validated processing at agreed size; 10-minute delivery timeout means incomplete.
- Measure 200/1,000/2,000 events and approaching byte limits before freezing limits and a reviewed retention/capacity policy. Never auto-prune history.
- Claude/Pippo explicitly accept/freeze or reject candidate option A, IDs/schema/limits/recovery. Missing/failing source recovery blocks saved-source collaboration; any narrower review-only decision needs a revised approved scope.

Decision: **DEFERRED pending actual two-Mac evidence and review.** COL-10 Copy content is independent.
