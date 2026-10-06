# Tasks 2/3 app workspace integration — final independent review

**Scoped verdict: no remaining blocking finding in the reviewed Tasks 2/3 integration or bounded SharedFeedback slice. Proceed to the dependent integration tasks. This is not actual-app, two-Mac, full-suite, release or design approval.**

Reviewed `/Users/philip.scholl/_WORK/markdown-reader` against approved `docs/superpowers/plans/2026-10-06-staging-collaboration.md`. Repository implementation was read-only for this reviewer; all independent probes and reports live under `/private/tmp`. Final hashes: `/private/tmp/folio-app-workspace-review-hashes.json`.

## Findings fixed and rechecked

1. **P1: main-thread provider path resolution.** Coordinator used `resolvingSymlinksInPath()` in MainActor source protection/selection/application. Those calls now run on its serial worker; MainActor compares cached paths. Source reads record symlink/hardlink aliases, case spelling is conservatively protected, and destination-changing saves are conservatively blocked while this preview protection is active. Existing broader reader/provider responsiveness still requires actual-app acceptance.
2. **P1: ambiguous registered source became unprotected on restart.** Register `a.md`, move original to `moved.md`, create a copy at `a.md`, restore a fresh coordinator. Original implementation returned false from `protectsSource(a.md)`. Manifest paths now remain protected even when the binding cannot resolve, and startup protection fails closed. Independent exact regression passed after failing before fix.
3. **P2: rejected document reconnect changed local access bindings.** A joined Mac could reconnect A onto unbound remote B's registered path; access store wrote A's binding before replica rejected the manifest collision. Exact previous binding bytes are now restored on rejection. Independent regression passed unchanged after failing before fix.
4. **P2: failed same-ID folder reconnect replaced the bookmark.** Reconnect to a copied same-ID folder whose inventory exceeds capacity left the original in-memory workspace active but persisted the new unusable bookmark. Exact previous bookmark bytes are now restored on later failure. Independent exact-byte regression failed before fix and passed after fix.
5. **P2: late source read could select a stale document.** New worker-read completion selected coordinator document before ReaderModel rejected its old generation. Worker completion now caches aliases only; ReaderModel selects only after its document-generation guard. Independent source-read selection regression passes; call-site order inspected.
6. **P2: startup verification suppressed solo source monitoring permanently.** A solo open finishing before absent-workspace restoration caused startMonitor to return without ever restarting. It now installs a dormant timer that performs no source checks until verification finishes, then follows ordinary solo/registered rules. Owner's real ReaderModel regression failed before fix and passed after fix; exact guard inspected.
7. **P2: identity disclosure was inaccurate.** Sheet said participant/device IDs stayed on the Mac even though events share them. Copy now explicitly says IDs are created locally and included in shared contributions.

Owner's independently identified failed-connect transaction and startup protection work was also inspected. Reconciliation retains last complete state; public-disabled construction has no worker; Staging hooks keep private highlights/journals separate and block ordinary shared source saves. Existing immutable transport and foundation guarantees were not broadly re-reviewed.

## Verification

- **Independent final native execution: 12 tests, 0 failures, 0 skips.** Five separate coordinator probes plus seven copied feedback-export tests. `/private/tmp/folio-app-independent-review-final.log`, completed 2026-10-06 15:54:47 local. Package `/private/tmp/folio-app-independent-review`; actual copied ReaderCore/coordinator/monitor, small BuildChannel stub, no ReaderModel/UI in that isolated package.
- Initial coordinator probes: 3 tests, 2 failures (binding rollback and ambiguous restart), `/private/tmp/folio-app-independent-review-red.log`; first fix rerun 3/3 `/private/tmp/folio-app-independent-review-green.log`.
- Bookmark probe: 1 test, 1 failing exact-byte assertion before fix, `/private/tmp/folio-app-bookmark-independent-red.log`; included in final five passing probes.
- **Owner's actual app-target final focused Staging run: 15 tests, 0 failures**, `/private/tmp/folio-app-workspace-final-focused.log`, completed 15:57:19. Reviewer read the completed output. Includes real ReaderModel solo startup external-reload regression, ordinary shared-save blocking/private-state test, actual local directory presenter event, and public-disabled gate assertion. This is owner-run evidence, not an independent full app test rerun.
- Startup-monitor RED: `/private/tmp/folio-app-workspace-solo-monitor-red.log`, 1 failed assertion, then final focused GREEN.

Bounded SharedFeedback review found no blocker: exact event/actor IDs, document/workspace scoping, private-data exclusion, coordinate/encoding labels, conservative source-intent/local-receipt distinction, limits and unknown coverage are represented. Seven existing tests independently passed twice. No mutation or filesystem dependency exists in that export API.

## Boundaries

No signed UI, OneDrive, actual security-scope permission loss/stalls, two-Mac delivery/convergence, Task 5 guarded source save/recovery, real IME/selection, at-capacity performance or Claude design review is claimed. Full public/Staging suite renderer failures are separate parent/owner evidence and were not converted into a passing full-suite claim. Tasks 4–8 acceptance remains outstanding. This report supports the next dependent coding slice only.
