# Folio first-stage plan review

Reviewed 6 October 2026. Scope: plan/spec review only; no implementation or runtime acceptance. Read the approved collaboration proposal, Copy content plan and isolated transport plan in full, and checked the load-bearing editor/save assumptions against current source.

## Verdict

**Spec: PASS. Quality: PASS for first-stage implementation planning. Both required corrections are addressed in the persisted plans.** COL-10 is independently implementable. COL-01 is an appropriately isolated experiment, not approval to implement downstream collaboration or evidence that OneDrive works. No change to the approved shared-review-first scope is needed.

This is an independent Codex plan review. It does not replace Claude's architecture/frontend/final review. No implementation, tests, live editor interaction, two-Mac transport check or Claude review was performed here.

## Addressed corrections

### 1. Protect the actual source editor from copy-state refreshes

The copy plan correctly reads the actual NSTextView and defers marked text, but must also protect it while publishing pending/success state. `MarkdownEditor.updateNSView` currently assigns `model.text` to `view.string` whenever they differ and clears the view's undo manager. A copy-busy update can therefore expose the existing overwrite path at exactly the time the plan promises to snapshot text newer than the model or wait for IME completion.

Specify the update ordering/guard: a copy request must not cause stale model text to replace newer or marked editor contents; pending/success UI updates alone must never clear undo. Add a test exercising `updateNSView` with a newer editor string and with marked text while copy is pending, then verify the final committed string is copied, selection/undo remain intact, and no stale pasteboard write occurs. This is a targeted protection in an already-listed file, not an editor redesign. Verified in the persisted Copy content plan: it now explicitly guards `updateNSView` against newer/marked text overwrite and tests that exact refresh path. Finding closed at plan level.

### 2. Make the real transport scenarios executable through the pilot runner

Task 4's CLI currently exposes `prepare-source`, but not the guarded `SourceRecovery.apply` operation. Task 5 requires each Mac to prepare **and save** SA/SB, and also requires delayed/reordered snapshot/event publication, while the listed `publish` command has no selective-publication mechanism. The implementation could otherwise pass library tests yet leave operators manually rewriting Markdown or moving files, bypassing the exact adapter being qualified.

Add a documented guarded source-apply command (or explicitly define `prepare-source --apply`), referencing the persisted prepared proposal by ID and confined to the disposable registered source. Expose a narrow pilot-only publication selection/fault control so operators can deliver an event before its snapshots and interrupt/restart publication using the same adapter. Include a way to emit the known task transition/resolution fixtures and source resolution if those real scenarios are required. Tests should prove CLI commands invoke the same prepare/apply/publish paths as the library and cannot target preexisting user documents. README must provide exact commands and expected IDs/hashes for the two-Mac scenarios.

Scoped re-review verified Task 4 now exposes `apply-source --proposal-id UUID` through the same `SourceRecovery.apply`, restricted to persisted validated preparation and the registered disposable source. `publish --only events|snapshots` and `--stop-after N` preserve queued artifacts and report incomplete/injected interruption explicitly. The plan supplies the exact prepare/apply/events-first/snapshots/restart sequence and CLI tests of the same library paths. This addresses the required pilot execution gap. Finding closed at plan level; no real pilot has run.

## Verified strengths and retained gates

- `ReaderModel.text` is the accepted Markdown; `acceptRenderedEdit` validates token, prior text and size. Existing script dispatch cannot itself acknowledge editor freshness. The copy plan's request IDs, token/document/mode checks, explicit failures and clipboard result handling address this correctly.
- The rendered editor currently commits via its normal serializer and has no composition lifecycle or snapshot acknowledgement. Adding a controller and event-sequence tests is justified; pure serializer tests would be insufficient.
- `DocumentReader.maximumBytes` is 8 MiB. `DocumentSnapshot.save` uses local file coordination and exact bytes before atomic replacement. Neither is a remote lock. The transport plan describes that limitation accurately.
- The isolated package avoids modifying private highlights/journals or product collaboration paths. Raw-byte hashes, immutable events/snapshots, pending dependencies, bounded scans and explicit concurrent heads align with the proposal.
- A process-interruption test does not prove power-loss durability. The plan explicitly retains that limitation; preserve it in the evidence ledger.
- Single-file workspace/document manifests and OneDrive conflict-copy behavior remain experimental. Real duplicate initialization must detect conflicting identity, including provider replacement/alternate filename outcomes; do not freeze the proposed format if a manifest can disappear without detectable evidence.
- Real two-Mac results remain NOT RUN until user-assisted testing occurs. Simulations cannot unlock COL-02–09 or saved-source rollout. Recovery must prove S0/SA/SB independently on both Macs even after OneDrive selects a visible Markdown winner.
- Actual WKWebView ordering, real IME in both editors, clipboard content, label/overflow, themes and accessibility remain runtime acceptance obligations. Unit tests alone do not establish those outcomes.

## Evidence

Current source inspected: `Sources/MarkdownReader/MarkdownEditor.swift`, `ReaderModel.swift`, `ReaderWebView.swift`, `web/editing.js`, `web/reader.js`, `Sources/ReaderCore/DocumentReader.swift`, `DocumentSnapshot.swift` and `package.json`, all under `/Users/philip.scholl/_WORK/markdown-reader`.

Planning inputs: `/Users/philip.scholl/_WORK/markdown-reader/docs/proposals/2026-10-06-collaboration.md`, `/private/tmp/folio-copy-plan.md`, `/private/tmp/folio-sync-plan.md`.


Final scoped re-review inputs: `/Users/philip.scholl/_WORK/markdown-reader/docs/superpowers/plans/2026-10-06-copy-content.md` and `2026-10-06-collaboration-feasibility.md`. A second Mac is reported available by the user; actual two-Mac access/configuration and testing remain unverified. No broader review or runtime check was performed during the scoped re-review.
