# Folio COL-01 Isolated Transport Feasibility Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for each task; the approved parent pipeline may assign isolated tasks and review them. Steps use checkbox syntax. This document authorizes no implementation or commits by this planning worker.

**Goal:** Prove or reject an asynchronous shared-folder recovery protocol before implementing Folio collaboration.

**Architecture:** A disposable Swift package exchanges immutable JSON events and raw-byte source snapshots between two independent replica directories. A deterministic simulated courier controls deliveries and failures. The same file adapter is exercised separately on two real Macs using the team's actual OneDrive account/folder type; simulation cannot pass that gate.

**Tech Stack:** Swift 5.9, macOS 14+, Foundation, CryptoKit, XCTest; no added external dependencies or hosted service.

**Spec:** `../specs/2026-10-06-collaboration-design.md` (read in full before execution).

## Constraints and verified context

- Implement only an isolated COL-01 experiment. Do not modify `Sources/MarkdownReader`, `Sources/ReaderCore`, existing tests, root `Package.swift`, JS, release feeds, private annotations or journals. No product UI, profiles, watched-folder sidebar, threaded comments, feedback migration or release.
- Source checkout is `/Users/philip.scholl/_WORK/markdown-reader`; selected `[PP] Folio - The Markdown Reader` workspace is not a replacement source root. Verify the exact checkout and write authority before execution; do not relocate the app or substitute a sibling checkout.
- Architecture and final acceptance remain with Claude/Pippo. All format/limit decisions below are experimental candidates; freeze them only after measured COL-01 acceptance and review.
- Current `DocumentSnapshot.save(_:to:)` coordinates one local raw-byte compare-and-write; it is not a distributed lock. `ReaderModel.startMonitor()` polls size/date once per second; equal-size/equal-time changes can escape that monitor.
- `DocumentReader.maximumBytes` is 8 MiB. Existing snapshot tests cover UTF-8/UTF-16 BOMs and CRLF; `EverydayReliabilityTests` covers same-metadata conflict at save time. Existing highlight/journal hashes mean decoded-source UTF-8, not raw file bytes; do not reuse those hashes for snapshot identity.
- Existing `HighlightStore`/`EditJournalStore` are private local path-keyed stores. Importing experimental events must never call their record/save methods or claim local authorship.
- No deletion inferred from a missing transport file. No automatic pruning, CRDT, clock-based last-writer-wins, cloud transaction or remote-received claim.

## Review focus

- Same ID with different bytes, conflicting manifests and copied documents must halt the affected identity instead of picking an arrival-order winner (Task 1/2).
- Missing parents/snapshots, crash windows and temporarily unavailable cloud items retain pending state and full recoverable local bytes (Task 2/3/5).
- Concurrent Done/Reopen and source saves preserve all competing heads; explicit resolution names every head being superseded (Task 2/3).
- Malformed/oversized files and history capacity exhaustion cannot destroy originals or produce a deceptively complete derived state (Task 1/2).
- Equal-size/equal-time replacements, renames and unseen external-editor edits require byte checks, explicit reconnection or an honest recovery gap (Task 3/5).

## Proposed file boundary

Create only these paths under the verified source checkout during future execution:

- `experiments/CollaborationTransport/Package.swift` — independent library, CLI and XCTest targets; root package unchanged.
- `experiments/CollaborationTransport/Sources/TransportProbe/Protocol.swift` — schema, identities, raw hashes and experimental limits.
- `experiments/CollaborationTransport/Sources/TransportProbe/ReplicaStore.swift` — bounded scan, immutable import/export, local outbox and reconciliation.
- `experiments/CollaborationTransport/Sources/TransportProbe/Reducer.swift` — causal review/source state, pending dependencies, explicit conflicts.
- `experiments/CollaborationTransport/Sources/TransportProbe/SourceRecovery.swift` — durable source preparation, guarded local write and recovery export.
- `experiments/CollaborationTransport/Sources/folio-transport-probe/main.swift` — disposable pilot commands and JSON ledger.
- `experiments/CollaborationTransport/Tests/TransportProbeTests/{Protocol,Replica,SourceRecovery,Pilot}Tests.swift` — meaningful invariants and deterministic failure injection.
- `experiments/CollaborationTransport/Tests/TransportProbeTests/Support/SimulatedCourier.swift` — test-only independent-replica delivery scheduler.
- `experiments/CollaborationTransport/README.md` — exact disposable pilot runbook; provisional protocol and limits.
- `docs/experiments/2026-10-06-col-01/DECISION.md` — acceptance ledger; real gate starts `NOT RUN`, scope remains blocked.

No runtime artifacts are checked into source; local test data lives in temporary directories and real pilot data only in an explicitly selected disposable OneDrive subfolder. Do not write to users' existing Markdown.

## Experimental schema and limits

Transport layout: `Folio Review/workspace.json`, `documents/<documentID>.json`, `events/<eventID>.json`, `snapshots/<rawSHA256>.bin`. Local durable state/outbox is a separate per-device directory outside OneDrive. `.tmp` files are not imported. All IDs are canonical UUID strings; source revisions are lowercase SHA-256 of exact file bytes, including BOM and line endings.

`workspace.json` binds schema 1 and one workspace UUID. One creator initializes it; the second device explicitly joins that UUID. Document registration binds one UUID to a relative path and initial raw hash. No content hash alone implies document identity. Local-only root moves retain IDs; a source rename or duplicate/conflicting registration returns `needsReconnection` in COL-01 rather than guessing. Concurrent workspace initialization is a visible manifest conflict; no merging.

`ProbeEvent: Codable, Equatable` fields: `schemaVersion: Int`, `id/workspaceID/documentID/participantID/deviceID: UUID`, `parents: [UUID]`, `displayTime: Date`, `payload: ProbePayload`. Payload is one of `comment(id: UUID, text: String, sourceRevision: String)`, `task(taskID: UUID, state: ProbeTaskState, supersedes: [UUID], sourceRevision: String)`, `sourceProposal(baseRevision: String, proposedRevision: String)`, `sourceResolution(proposedRevision: String, supersedes: [UUID])`. The task identifier is preseeded in the fixture, not inferred from duplicate labels or line offsets. A source proposal means recoverable intended bytes, not proof that `.md` was published or received remotely.

`ProbeLimits.pilot`: maximum event file 64 KiB; source snapshot 8 MiB; workspace/document manifest 16 KiB; 2,000 accepted events/workspace; 256 distinct snapshots/workspace; 128 MiB total admitted transport bytes; 5,000 candidate files per scan; 32 parents and 32 superseded IDs/event; comment text 8,000 UTF-8 bytes; 100 retained diagnostics plus aggregate counts. Test with smaller injected limits. A pending event counts toward the event budget. Validate references, parent document/workspace identity, hashes, schema, UTF-8 text and causal cycles. Schema mismatch/invalid file produces a bounded diagnostic and preserves the original; valid siblings still import.

Capacity is a whole-reconciliation outcome: if count/byte/scan limits are exceeded, report `capacityExceeded`, retain all disk artifacts and disable new actions/source writes. Do not return a partial state as complete or choose the first N events by arrival order. Previous results may be displayed only as explicitly stale. Export evidence to a separately chosen directory; require a reviewed retention/transport decision to continue. Do not auto-delete history.

## Interfaces to freeze inside the experiment

- `ProbeLimits` and `ProbeEvent` above; `ProbeTaskState: String, Codable { open, inProgress, done }`.
- `SnapshotID.hash(_ bytes: Data) -> String` hashes raw bytes only.
- `ProbeReducer.reduce(events: [ProbeEvent], snapshots: [String: Data]) -> ProbeState`: pure deterministic replay, output sorted by UUID for stable comparison. `ProbeState` exposes accepted IDs, pending dependency IDs, comment IDs, task heads, source heads and conflict head sets. Arrival time/wall clock never decides a head.
- `ReplicaStore.init(localRoot: URL, sharedRoot: URL, workspaceID: UUID, limits: ProbeLimits)`; `enqueue(_ event: ProbeEvent, snapshots: [String: Data]) throws`; `publishOutbox() throws -> PublishReport`; `reconcile() throws -> ReconciliationReport`; `exportEvidence(to: URL) throws`. Reports distinguish complete, pending, identityConflict, capacityExceeded, unavailable; diagnostics/counters are bounded.
- `SourceRecovery.prepare(event: ProbeEvent, base: Data, proposed: Data, store: ReplicaStore) throws -> PreparedSource`; `apply(_ prepared: PreparedSource, to: URL) throws -> LocalApplyResult`; `recover(proposalID: UUID, from: ReplicaStore, to: URL) throws -> RecoveryExport`. `PreparedSource` contains IDs/hash references and local durable paths; `LocalApplyResult` is applied, unchanged, conflict or unavailable. Only a sourceProposal can be prepared; validate snapshots' exact hashes and lengths before staging.
- `SimulatedCourier.transfer(from: URL, to: URL, relativePaths: [String], repeats: Int = 1) throws` copies exact bytes, without sharing either replica's memory or local outbox; schedule and directory reconstruction are controlled by tests. A conflicting existing immutable path retains both variants as evidence and reports identityConflict.

## Task 1 — Bounded protocol and stable identities

- [ ] Create the independent package and write `ProtocolTests`: invalid schema/UUID/hash/reference rejected, exact 64 KiB boundary accepted and +1 byte rejected, snapshot 8 MiB/+1, comment 8,000/+1, parents 32/33, wrong raw hash rejected. UTF-8 BOM/UTF-16 BOM/CRLF variants have distinct raw IDs while exported bytes are identical to inputs. Conflicting manifests and copied identical Markdown require reconnection.
- [ ] Run `swift test --package-path experiments/CollaborationTransport --filter ProtocolTests`; record the RED failure from missing behavior.
- [ ] Implement `Protocol.swift` and manifest checks with bounded `FileHandle` reads (`limit + 1`); validate before decoding/loading whole content. Immutable existing same bytes are idempotent; differing bytes never overwritten. Reject paths escaping the root, including symlinks; probe creates no user-facing access grants.
- [ ] Re-run the filter; require GREEN. No existing product code or tests changed.

## Task 2 — Two independent replicas, causal replay and bounded reconciliation

- [ ] Write `ReplicaTests.testTwoReplicasConvergeAfter100EventsEach`: fixed UUIDs and fixture root; A and B each enqueue 100 distinct actions while delivery is disconnected; publish into separate shared roots; transfer in reverse order with repeated deliveries, missing parents and skewed display clocks; destroy/recreate stores halfway. After all dependencies arrive, assert both accepted ID sets equal the exact 200 generated IDs, states equal, each comment occurs once, both outboxes survive restart, and no received event becomes a new authored event.
- [ ] Add tests for concurrent task Done/Reopen => two visible heads; a resolution causally referencing/superseding both => one head; a resolution omitting a concurrent head => conflict remains. Test duplicate ID/different bytes quarantines the affected identity; cycles/wrong-document parents rejected; missing parents remain pending and do not block unrelated comments.
- [ ] Add cap tests with injected tiny limits: boundary succeeds; +1 event/snapshot/total byte/candidate file returns capacityExceeded with no complete partial state, no disk deletion and no new source publication. Import one malformed/unknown/oversized event alongside a valid event; assert valid import and bounded diagnostics. Thousands of bad candidates terminate at the scan bound with an explicit incomplete result.
- [ ] Run `swift test --package-path experiments/CollaborationTransport --filter ReplicaTests` for RED.
- [ ] Implement the interfaces above in ReplicaStore/Reducer and test support. Durably stage an event plus its snapshots in a new local transaction directory, sync file handles, then atomically rename that directory to `ready`; only ready records publish. Publish immutable artifacts independently; success means local shared-folder materialization only. A full scan recomputes state from disk after startup/wake/missed notifications; implement no production watcher. Lexical UUID order breaks display ties only; causal ancestry determines supersession. Treat snapshots/parents arriving later as pending.
- [ ] Re-run for GREEN and replay fixed shuffled schedules for seeds 1...20; compare exact state and ID sets. Inject crashes before/after ready rename and after each published artifact; restart retains every acknowledged local action and republishes idempotently. Partial preparations cannot be reported acknowledged.

## Task 3 — Source publication and full-byte recovery

- [ ] Write `SourceRecoveryTests.testConcurrentSourceWritersRecoverBothVersions`: both start with exact base S0; A prepares SA and B prepares SB, stages base/proposed snapshots and proposal events locally before modifying either replica's `.md`; both guarded local writes succeed offline. Deliver events before snapshots, omit one snapshot temporarily, then overwrite `.md` replicas with the simulated OneDrive winner. After complete delivery, both expose competing proposal IDs and recover S0, SA and SB byte-for-byte regardless of `.md` winner. Pending missing snapshots never claim recoverability.
- [ ] Add crash injection at local preparation, before `.md`, immediately after `.md`, and midway through shared publication. Restart can distinguish prepared/local-applied/unknown-interrupted outcomes without erasing intent. A proposal from a failed local compare remains recoverable but is explicitly not a successful save.
- [ ] Add same-size/same-time replacement conflict; unavailable/deleted original; unchanged save; BOM/CRLF/emoji raw recovery; staged checksum mismatch; storage/write failure before preparation commit leaves `.md` unchanged. Observed external bytes become explicit recovery evidence; never-observed external content yields `externalRecoveryGap`, with no fabricated author or complete-history claim.
- [ ] Run `swift test --package-path experiments/CollaborationTransport --filter SourceRecoveryTests` for RED.
- [ ] Implement SourceRecovery. Reuse production behavior as a reference: local NSFileCoordinator + exact base-byte comparison + atomic `.md` replacement, bounded at 8 MiB. Do not change/import the production package or call this a lock. Durable preparation is mandatory before `.md` write; remote publication can be delayed offline. Local phase receipts use atomic writes in the local transaction directory. If a crash prevents receipt, infer only what current bytes establish; retain unknown status otherwise. An unresolved branch blocks another source write until an explicit recovery/resolution operation; resolution causally supersedes all acknowledged branch events and retains historic snapshots.
- [ ] Re-run for GREEN. Test explicit resolution after SA/SB preserves both originals; a later-arriving unknown third branch reopens conflict. Include a split-brain first save with independent empty source histories and the same raw baseline, so detecting branches cannot rely on preexisting shared causal parents alone.

## Task 4 — Disposable pilot runner and reproducible evidence

- [ ] Implement CLI commands with required `--local-root` and `--shared-root` (distinct paths): `init --workspace-id UUID --document-id UUID`, `join --workspace-id UUID`, `generate --participant-id UUID --device-id UUID --count 100 --seed 1`, `prepare-source --base PATH --proposed PATH` (prints a persisted proposal UUID), `apply-source --proposal-id UUID` (loads that durable preparation, validates workspace/document and hashes, then calls the same `SourceRecovery.apply` against the registered disposable source), `publish [--only events|snapshots] [--stop-after N]`, `scan`, `recover --proposal-id UUID --output PATH`, `export --output PATH`. Source fixtures are confined to the created disposable pilot root; commands never touch a preexisting user document. `init` refuses nonempty/unmarked roots and leaves duplicates as explicit conflicts.
- [ ] Pilot-only fault controls: `--only` publishes exactly that artifact class, leaving all others queued; `--stop-after N` exits with an explicit injected-interruption result after N immutable artifacts without losing outbox state. Neither mode is a successful complete publication claim. README includes the exact sequence: prepare → capture proposal UUID → apply-source on each Mac → publish --only events → scan (pending snapshots) → publish --only snapshots → scan (conflicting recoverable source branches). Repeat publish --stop-after 1, restart, then publish without options. No manual write to `.md` may substitute for apply-source.
- [ ] `PilotTests` invoke the CLI and verify it exercises the same library preparation/apply/publish paths; compare original source bytes on failed apply and all expected outbox artifacts after interruption/retry. Also cover command validation, initialization/join, unavailable folder, JSON report round trip, bounded evidence export and positive/negative exit statuses. `scan` reports locally received IDs/state and missing snapshots; publish never emits a remote sync confirmation. Export includes raw hashes, exact IDs, schema/limits, participant/device labels, local monotonic processing duration, machine/run IDs and timestamps; no OneDrive credentials or private journals.
- [ ] Run `swift test --package-path experiments/CollaborationTransport` and `swift build --package-path experiments/CollaborationTransport`; require GREEN. Optional root `swift test` verifies unchanged app compatibility after the experiment exists, with its actual output recorded; do not replace it with a made-up pass count. Write the real-run steps below into README and leave DECISION's real gate `NOT RUN`.

## Task 5 — Actual two-Mac OneDrive gate (unavailable and unverified here)

Requires two Macs, installed OneDrive, the actual Personal/Business/shared-folder configuration, actual shared write permission and a human operator on each device. None is established by this planning task. Simulation GREEN unlocks conducting this pilot, not COL-02–09 implementation.

- [ ] Record both macOS/OneDrive versions, account/folder type, folder sharing setup, Files On-Demand state, offline availability, provider limits and selected pilot paths. Use a newly created disposable shared subfolder; A initializes, B joins only after the expected manifest arrives. Test duplicate initialization separately and preserve conflicting artifacts.
- [ ] On each Mac run 100 locally acknowledged events, including events created while disconnected/OneDrive paused. Restart the probe during pending outbox publication. Resume OneDrive; scan until both ID ledgers contain the exact 200 IDs and derived states match. Poll by operator command; no remote availability inferred from local successful publication.
- [ ] Exercise real order/delay by staggering event and snapshot publication. Repeat with same-name participants/different IDs, simultaneous checkbox status events, cloud-only/unavailable files, folder rename/reconnection, conflicting document registrations, dropped local notification assumptions and revoked permissions. Last readable bytes stay available; errors/pending references remain explicit. Record OneDrive-generated alternate/conflict filenames; inspect contained IDs instead of treating filename shape as authoritative if harmless renaming occurs. Differing bytes under an ID remain conflicts.
- [ ] Both Macs load S0, pause delivery, prepare and save SA/SB, then reconnect. Permit OneDrive to choose/replace the visible `.md`; require both devices independently recover exact S0/SA/SB from immutable artifacts and show the unresolved branch. Test interrupted publication and delayed/missing snapshots. If either version cannot be recovered after completed delivery, shared source editing fails the gate.
- [ ] Measure local scan/reducer latency with monotonic clocks; target validated received activity processing <=2 seconds at the agreed pilot size. Measure each origin event's observed remote receipt latency separately with recorded clock synchronization/offset uncertainty; if clocks are insufficiently synchronized, report a bounded estimate or unknown, not a precise one-way claim. Record observed min/median/p95/max and non-delivery/timeout cases; no universal OneDrive promise. A 10-minute operational timeout is recorded as delivery incomplete, not a promise or proof of loss.
- [ ] Export each device's evidence, compare exact IDs/raw snapshot hashes/state, record every scenario PASS/FAIL/NOT RUN and local vs remote timings in DECISION. Do not mark a missing/paused snapshot as accepted recovery. Test 200/1,000/2,000 events and approaching byte limits before choosing pilot limits; no retention auto-pruning.
- [ ] Claude/Pippo review the evidence and freeze or reject candidate format/IDs/limits/recovery protocol. Full COL-01 PASS requires all required real scenarios plus simulations. Partial pass supports a new explicit review-only scope decision; it does not silently approve saved source sync. On failed/unrun transport/recovery, stop collaboration work and choose narrower review-only scope or option B/C through a revised decision. COL-10 remains independent.

## Concrete uncertainties and decision ledger

- Pippo confirmed a second Mac is available for user-assisted testing. Actual OneDrive account/folder type, operator access and test results remain unverified. Status: real gate NOT RUN; downstream collaboration blocked.
- Atomic local rename/file flush is not proof of power-loss durability on every filesystem or multi-file cloud atomicity. Test process-interruption recovery now; record filesystem assumptions and whether stronger fsync/directory barriers are required before claiming power-loss protection.
- OneDrive conflict-copy names, hidden/sibling folder replication, Files On-Demand hydration, pause semantics and cross-device delivery need direct measurement. Bounded application scans cannot make arbitrary provider reads nonblocking; pilot operator must record hangs/timeouts and reject unsupported behavior rather than calling it a passing unavailable-state test.
- Concurrent same-base proposals can be identified, but unseen external-app versions cannot be reconstructed. Saved outcomes and recoverable intent are separate facts; each observed gap must remain explicit.
- Rename/copy identity is deliberately fail-closed in the probe; seamless identity-preserving document moves are not established. If the required pilot expects automatic rename recovery, specify and prove the evidence policy before freezing option A.
- Limits are proposed experiment constants, not final product acceptance. 128 MiB/256 snapshots can fill rapidly near the 8 MiB source limit; no downstream UI or rollout until measured size/growth and an explicit capacity recovery policy are approved.
- No production editor, draft, task-anchor, security-scoped bookmark or private-store integration is exercised. COL-01 cannot establish those downstream guarantees.

**Planning output only:** current source was read; no implementation, dependencies, cloud resources, commits or tests changed/run. This plan's real OneDrive gate remains unverified.
