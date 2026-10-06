# COL-01 disposable transport probe

This independent macOS Swift package tests an experimental recovery protocol. It does not integrate with Folio or establish OneDrive delivery. The actual two-Mac gate is **NOT RUN**; COL-02–09 remain blocked pending Claude/Pippo review. Use only newly created disposable roots. Never point these commands at personal Markdown, an existing shared workspace, private annotations, or a journal.

Build and test from the Folio checkout:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --package-path experiments/CollaborationTransport
swift build --package-path experiments/CollaborationTransport
PROBE="$(swift build --package-path experiments/CollaborationTransport --show-bin-path)/folio-transport-probe"
```

Xcode must be installed: the separately installed Command Line Tools on the development Mac do not contain XCTest. No dependencies are added to Folio's root package.

## Experimental contract

`Folio Review/workspace.json`, `documents/<UUID>.json`, `events/<UUID>.json`, `snapshots/<rawSHA256>.bin` live below the selected shared pilot root. The local root is a separate directory outside OneDrive; it contains identity bindings, immutable received evidence, ready outbox transactions, and local source phase receipts. Only an atomically renamed ready transaction is acknowledged. Files ending `.tmp` are not imported. Transactions are retained after publication so retry/restart is idempotent. Received events retain their original IDs/participants/devices and are not echoed into a new authored outbox.

Schema 1 uses canonical uppercase UUID strings and lowercase SHA-256 of **exact bytes**, including encoding/BOM and line endings. Task states are `open`, `inProgress`, `done`; task IDs are fixture identities. Causal parents and explicit supersession determine heads; clocks only label activity. Concurrent source proposals branch even when both have no parents. A source proposal describes recoverable intended bytes, never remote delivery or a successful source save. Source apply separately verifies the full current bytes inside local `NSFileCoordinator` coordination. This is local coordination, not a distributed lock.

Pilot limits: event 64 KiB; snapshot 8 MiB; manifest 16 KiB; 2,000 distinct events including pending; 256 distinct snapshots; 128 MiB admitted bytes; 5,000 candidate files per whole reconciliation across shared, received, outbox and conflict trees; 32 parents/superseded IDs; comments 8,000 UTF-8 bytes; 100 retained diagnostics plus aggregate counts. A capacity result has no complete partial state and disables new actions/publication/source apply. There is no automatic deletion or pruning. Export may itself be bounded; its ledger must disclose incomplete coverage. These are candidates, not frozen product limits. Scan and filesystem reads are synchronous; Files On-Demand hangs/hydration must be measured separately.

Identical immutable bytes are idempotent. A different byte sequence under an event identity quarantines that identity and retains both variants; conflicting workspace/document manifests stop actions. Copied registrations or missing/renamed source files require explicit reconnection. The probe deliberately supports one registered disposable source, `fixture.md`; content hashes alone never infer document identity. Trusted folder access and actor UUIDs are not authenticated authorship.

Commands require `--local-root PATH --shared-root PATH`, separate, non-nested paths. `init` requires empty roots and creates its own disposable `fixture.md`. `join` requires the expected manifest and UUID, and refuses an unmarked nonempty local root. Inputs to `prepare-source` must be within the already marked disposable roots. `recover`/`export` require a separate empty output directory. Output is one JSON result containing machine/run IDs, timestamps and monotonic local processing duration. `scan.reconciliation` round-trips as the library's report and names locally received IDs, pending events, missing hashes and competing heads. It is not a remote confirmation.

`publish --only events` and `--only snapshots` materialize only that class and report `pending`; the other class stays queued. `publish --stop-after N` deliberately stops after N immutable artifacts and reports `injectedInterruption` with exit 3. Restart and unrestricted publication retain/retry the same outbox. Exit 0 means the requested local operation completed (or an explicitly reported pending class publication/scan); exit 2 means invalid/conflicted/unavailable/capacity; exit 3 means injected interruption. Check JSON status and dependencies even on exit 0.

## Actual two-Mac pilot — NOT RUN

Pippo has a second Mac available. Actual OneDrive account/folder type, permissions, versions, Files On-Demand behavior and cross-device receipt remain unverified. A human on each Mac conducts these steps and records the evidence in `docs/experiments/2026-10-06-col-01/DECISION.md`.

On **each Mac**, first record macOS/OneDrive versions, Personal/Business account and shared-folder type, sharing permissions, Files On-Demand/offline state, provider limits, clock-offset uncertainty and operator. Select the same shared OneDrive parent as locally mapped on that Mac. Substitute **only** `REPO` and `ONEDRIVE_PARENT` with verified absolute paths; the remaining fixture UUIDs/commands are fixed. Use a fresh pilot subfolder name if the named one already exists. A initializes once; B never initializes this same pilot.

**Mac A setup:**

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
REPO='/Users/philip.scholl/_WORK/markdown-reader'
ONEDRIVE_PARENT='/replace/with/verified/shared/OneDrive/parent'
SHARED="$ONEDRIVE_PARENT/Folio-COL01-disposable-20261006"
LOCAL='/private/tmp/folio-col01-A-20261006'
EVIDENCE='/private/tmp/folio-col01-evidence-A-20261006'
swift build --package-path "$REPO/experiments/CollaborationTransport"
PROBE="$(swift build --package-path "$REPO/experiments/CollaborationTransport" --show-bin-path)/folio-transport-probe"
"$PROBE" init --local-root "$LOCAL" --shared-root "$SHARED" --workspace-id 00000000-0000-0000-0000-000000000001 --document-id 00000000-0000-0000-0000-000000000002
```

**Mac B setup:** choose the local mapping of the same parent and a checkout of this same experiment. Wait until OneDrive has delivered A's manifest and `fixture.md`, and inspect the expected UUID. Then join:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
REPO='/replace/with/Folio/checkout'
ONEDRIVE_PARENT='/replace/with/verified/shared/OneDrive/parent'
SHARED="$ONEDRIVE_PARENT/Folio-COL01-disposable-20261006"
LOCAL='/private/tmp/folio-col01-B-20261006'
EVIDENCE='/private/tmp/folio-col01-evidence-B-20261006'
swift build --package-path "$REPO/experiments/CollaborationTransport"
PROBE="$(swift build --package-path "$REPO/experiments/CollaborationTransport" --show-bin-path)/folio-transport-probe"
"$PROBE" join --local-root "$LOCAL" --shared-root "$SHARED" --workspace-id 00000000-0000-0000-0000-000000000001
```

**Both:** pause OneDrive / disconnect delivery using the provider's UI, then verify that the disposable folder is still readable offline. Generate while disconnected, with separate actor/device IDs:

```sh
# A
"$PROBE" generate --local-root "$LOCAL" --shared-root "$SHARED" --participant-id 00000000-0000-0000-0000-000000000003 --device-id 00000000-0000-0000-0000-000000000004 --count 100 --seed 1 > /private/tmp/folio-col01-origin-A.json
# B
"$PROBE" generate --local-root "$LOCAL" --shared-root "$SHARED" --participant-id 00000000-0000-0000-0000-000000000005 --device-id 00000000-0000-0000-0000-000000000006 --count 100 --seed 2 > /private/tmp/folio-col01-origin-B.json
```

Run the following **on each Mac**. Exit 3 on the first command is expected. Stop/restart the executable (each invocation is a fresh process), and retry:

```sh
"$PROBE" publish --local-root "$LOCAL" --shared-root "$SHARED" --stop-after 1
"$PROBE" publish --local-root "$LOCAL" --shared-root "$SHARED"
"$PROBE" scan --local-root "$LOCAL" --shared-root "$SHARED"
```

Resume OneDrive. On each Mac run `scan` until the exact union of A/B origin IDs is locally received (200 IDs), dependencies are complete and derived states agree. Save each scan with receipt timestamp; don't infer receipt from a successful `publish`. An operator's 10-minute timeout means delivery incomplete. Compare exported IDs with the saved origin ledgers, not just a count. Repeating scan is the deliberate missed-notification/wake test; no watcher exists in this probe.

**Concurrent source test:** on each Mac, ensure its disposable `fixture.md` is the original baseline, pause OneDrive again, then make local base/proposal fixtures. These commands copy/read `fixture.md`; they do not manually edit it. On A:

```sh
cp "$SHARED/fixture.md" "$LOCAL/base.bin"
printf '# Disposable pilot\nMac A intended version 👋\r\n' > "$LOCAL/proposed.bin"
"$PROBE" prepare-source --local-root "$LOCAL" --shared-root "$SHARED" --base "$LOCAL/base.bin" --proposed "$LOCAL/proposed.bin" > "$LOCAL/prepared.json"
PROPOSAL=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["proposalID"])' "$LOCAL/prepared.json")
"$PROBE" apply-source --local-root "$LOCAL" --shared-root "$SHARED" --proposal-id "$PROPOSAL"
"$PROBE" publish --local-root "$LOCAL" --shared-root "$SHARED" --only events
```

On B run the **same** block with this one changed fixture line:

```sh
cp "$SHARED/fixture.md" "$LOCAL/base.bin"
printf '# Disposable pilot\nMac B intended version 👋\r\n' > "$LOCAL/proposed.bin"
"$PROBE" prepare-source --local-root "$LOCAL" --shared-root "$SHARED" --base "$LOCAL/base.bin" --proposed "$LOCAL/proposed.bin" > "$LOCAL/prepared.json"
PROPOSAL=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["proposalID"])' "$LOCAL/prepared.json")
"$PROBE" apply-source --local-root "$LOCAL" --shared-root "$SHARED" --proposal-id "$PROPOSAL"
"$PROBE" publish --local-root "$LOCAL" --shared-root "$SHARED" --only events
```

Capture **both proposal UUIDs** from the JSON results. Only successful `apply-source` exercises the guarded source write; a manual `.md` write cannot substitute. Resume OneDrive before publishing any snapshots. Scan on both Macs until the *other* proposal arrives and its missing snapshot hashes are explicitly pending. Local snapshots in each Mac's own durable outbox are already known locally; only the received remote branch should be missing. Allow OneDrive to choose/replace the visible `.md`, and record every generated conflict/alternate filename. Never interpret the winner as a source resolution.

Then on **both Macs**:

```sh
"$PROBE" publish --local-root "$LOCAL" --shared-root "$SHARED" --only snapshots --stop-after 1
"$PROBE" publish --local-root "$LOCAL" --shared-root "$SHARED" --only snapshots
"$PROBE" publish --local-root "$LOCAL" --shared-root "$SHARED"
"$PROBE" scan --local-root "$LOCAL" --shared-root "$SHARED"
```

Wait for snapshot delivery and scan again. Each independent state must expose both proposal IDs as conflicting source heads with no missing snapshots. Fill these **recorded** UUIDs, then recover each proposal separately on **each Mac**, to fresh empty directories:

```sh
A_PROPOSAL='replace-with-recorded-A-proposal-UUID'
B_PROPOSAL='replace-with-recorded-B-proposal-UUID'
"$PROBE" recover --local-root "$LOCAL" --shared-root "$SHARED" --proposal-id "$A_PROPOSAL" --output "$LOCAL/../recovered-A-on-this-Mac-20261006"
"$PROBE" recover --local-root "$LOCAL" --shared-root "$SHARED" --proposal-id "$B_PROPOSAL" --output "$LOCAL/../recovered-B-on-this-Mac-20261006"
"$PROBE" export --local-root "$LOCAL" --shared-root "$SHARED" --output "$EVIDENCE"
```

Compare exported `base-<hash>.bin` and `proposed-<hash>.bin` with both origin fixtures byte for byte (including BOM/CRLF/emoji). A remote recovery record says `intendedOnly`; the local receipt separately describes its save outcome. `externalRecoveryGap` remains true because this probe cannot reconstruct never-observed external-editor versions. Observed compare-conflict bytes are retained as explicit evidence without invented authorship.

Run separate disposable pilot roots for duplicate initialization/conflicting registrations, rename/reconnection, identical display names with different IDs, simultaneous Done/Reopen, cloud-only/unavailable source/snapshot files, revoked permission, process interruption before/after source write, and 200/1,000/2,000-event capacity/latency/growth trials. The library XCTest fixtures cover causal source resolution and task heads; the CLI intentionally does not author those task/resolution payloads. Use the reviewed event fixture/library harness for those operator scenarios; they are **NOT RUN** until observed on both real devices.

Record local monotonic scan/reducer duration separately from origin-to-remote observed receipt. Target validated received processing ≤2 seconds at agreed pilot size; record measured min/median/p95/max and non-deliveries. Without clock synchronization/offset bounds, remote one-way latency is unknown. No universal cloud deadline is claimed. Any unrecoverable acknowledged version or unsupported provider behavior fails the saved-source gate. Claude/Pippo must freeze or reject these candidate contracts and decide whether a narrower review-only scope is acceptable. No downstream collaboration or release follows automatically from simulation results.

## Durability and remaining limits

Files are flushed with `FileHandle.synchronize`; immutable materialization uses a same-directory temporary file and exclusive hard-link creation, and a ready directory is renamed atomically locally. This proves the exercised process-interruption windows, **not** power-loss persistence across every filesystem. Parent-directory fsync barriers, real provider hard-link/rename support, network volumes and file hydration need measurement. Cloud multi-file atomicity is never claimed.

Prepared, applying and final phase receipts are local only. After an interrupted write, current exact bytes establish prepared/localApplied when possible; anything else is `unknownInterrupted`. Failed compare proposals stay recoverable but are not successful saves. Superseded preparations, source conflicts and pending source branches block further source writes; explicit library resolution retains historical snapshots and an unknown later branch reopens conflict. Local durable recovery remains available when the shared folder or source is unavailable; scans explicitly label retained local evidence stale, and new actions stay blocked. No external source histories are fabricated. No production watcher, bookmark/access grants, editor/private-store integration, authenticated identity, power-loss test or OneDrive account access has been implemented here.
