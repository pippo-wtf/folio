# Folio collaboration foundation review — final

**Final verdict: no remaining actionable blocker from this foundation review. All six reproduced defects are fixed and independently rechecked. Clear to proceed to app integration, subject to its own required tests and review.**

Final narrow verification: 2026-10-06, tool timestamp 15:44:57. Six unchanged independent core probes plus the existing SharedWorkspaceStore case-alias root regression passed: **7 tests, 0 failures, 0 skipped**. Source copied unchanged into the isolated scratch package after both owners declared their fixes frozen. Log: `/private/tmp/folio-foundation-review-final-seven.log`.

The sixth fix now compares physical directory identity across both roots' ancestors before any metadata creation. The core probe verifies rejected nested case-alias localRoot leaves no private-cache directory inside sharedRoot; the workspace probe independently verifies rejected local storage leaves no local directory inside sharedRoot. The initial five probes remain green.

Final source SHA-256 snapshot: `/private/tmp/folio-foundation-review-final-hashes.json`. This review did not modify the repository; only scratch probes/reports were written. New app integration changes were excluded.

Limitations: these are isolated native filesystem/core tests, not signed-app bookmark/permission acceptance, OneDrive behavior, physical two-Mac convergence, actual UI source-save acceptance, or universal power-loss durability. Full-repository/native regression results remain the parent/owners' separate evidence. Prior matcher report records 13 isolated tests; this final narrow rerun did not rerun those tests.

---

Scope: approved Task 1 foundations, local portions of Task 2, Task 6 task matcher, Task 7 private seen IDs. Read-only repository review. Scratch probes only; no OneDrive, signed-app, or real two-Mac claim.

Six runtime-confirmed blockers found during review:

1. P1 — Source resolution after sequential saves is rejected. Reducer observed-head validation subtracts explicit supersedes but misses implicit source-base ancestry removal used by final head derivation. Prepare/apply base→A→B then resolve current head B: resolution is marked invalid; apply throws unresolved/superseded. Initial reducer lines 91–97. Fixed and independently verified.
2. P1 — Fresh-replica reconnect can alias another registered document's default manifest path. It checked only explicit local bindings, leaving two document UUIDs targeting b.md. Initial replica lines 79–87. Fixed and independently verified.
3. P1 — Corrupt local bindings silently become an empty map, allowing fallback to an old manifest path. After moving document to moved.md, placing an unrelated a.md, and corrupting bindings.json, sourceURL(original ref) returns the unrelated a.md. Initial replica lines 75–77 and 89–98. Fixed and independently verified.
4. P1 — Unreadable events directory silently disappears from enumeration. A chmod000 events directory containing an unseen event yields status=complete and coverageComplete=true. FileManager enumerator omitted an error handler (initial replica lines 181–200). Fixed and independently verified.
5. P1 — Case aliases register the same Mac file as two document identities. Registering a.md then A.md succeeds on this case-insensitive volume. Literal path comparisons do not establish filesystem uniqueness. Case probe explicitly skips on genuinely case-sensitive filesystems. Fixed and independently verified.

Integration contract observation: ReplicaStore and WorkspaceStore originally both used localRoot/bindings.json with incompatible Codable shapes. Local-store owner is moving workspace metadata to workspace-bindings.json with a permanent regression.

Evidence:
- /private/tmp/folio-foundation-review-probes/Tests/ReaderCoreTests/ReviewProbeTests.swift
- /private/tmp/folio-foundation-review-probes.log: first three probes, 3 tests / 5 failed assertions.
- /private/tmp/folio-foundation-review-permission.log: fourth probe, 1 test / 2 failed assertions.
- /private/tmp/folio-foundation-review-case.log: fifth probe, 1 test / 1 failed assertion (not skipped).
- First sandbox attempt could not write Swift module cache; actual runtime probes then ran with approved Xcode cache access.

Initial copied source SHA-256 (before fixes):
- CollaborationProtocol.swift: 8104a0c52bdb279a4ab983dbe353bc0e6b8a5d317752458150c1a91c9b1b785b
- CollaborationReducer.swift: 396e2f9fdc265a03489e1567bb2a765cf31e6a94b5202967495e4c6a3ee9e4f6
- CollaborationReplicaStore.swift: 2029fa59256e6002f571e1ba5e655ba6f428714e14852c9ff187ecfb720cc16d
- CollaborationSourceRecovery.swift: c5ac933526661c62b47f2edfb7a09ac9d6d81d109f07f05559308792a62a97d9

## Recheck 15:33 UTC-local tool timestamp

The five unchanged independent probes all passed against the final core snapshot: 5 tests / 0 failures, case-alias source registration test executed (not skipped). Log: /private/tmp/folio-foundation-review-final-probes.log. Snapshot hashes: /private/tmp/folio-foundation-review-final-hashes.json.

## Remaining blocker found in final boundary pass

6. P1 — Case-alias root overlap permits private storage writes inside shared folder before rejection. ReplicaStore.checkRoots compares resolved path strings but APFS aliases SHARED/shared are not necessarily canonicalized. Calling join with sharedRoot=<root>/shared and localRoot=<root>/SHARED/private-cache eventually throws but has already created <shared>/private-cache and copied local identity/evidence. This violates the private-storage separation/no-mutation gate. ReplicaStore lines 45–53 must reject physical ancestor overlap before any write. SharedWorkspaceStore had the same flaw; its owner reproduced two failed assertions and is implementing physical directory-identity ancestry checking.

Runtime proof: testCaseAliasCannotPlaceReplicaUnderSharedRoot, /private/tmp/folio-foundation-review-root-alias.log (1 test / 1 failed assertion, no skip). Existing source fixture and metadata stay under temporary scratch root; test cleans it after asserting. Core owner messaging failed with agent-thread-limit error; parent notified with exact repro and scope.

Historical checkpoint: five initial core blockers were resolved; root alias privacy boundary still required the final fix and rerun recorded below.
