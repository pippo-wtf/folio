# Folio local acceptance evidence audit — 2026-10-06

Read-only audit of `/Users/philip.scholl/_WORK/markdown-reader` tests and `docs/experiments/2026-10-06-staging-collaboration/`. No product/repository edits, app foreground changes, installation, provider changes or new broad test run.

## Established local evidence

- Independently inspected `/private/tmp/folio-comprehensive-public.log` and `folio-comprehensive-staging.log`: each reports 213 tests, zero failures. These cover the pre-modal-follow-up source; they do not cover subsequent fixes automatically.
- Core coverage is unusually broad: exact 300-event union for three offline simulated replicas, duplicate and reversed delivery, restart, delayed parent/snapshot, BOM/CRLF/emoji recovery, same-ID conflicting data quarantine, corrupt schemas/bindings, capacity fail-closed, distinct same-name identities, source conflict heads and late branches, permissions and path identity constraints.
- Native integration covers two independent participant stores, comments/replies/original authors, private exclusion, independent unread state, task status/source intent separation, conflicting source drafts/recovery, actual WebKit bridge, buffered saves and leave/quit, editor composition guards, and watcher debounce/fallback plus real directory-presenter nested atomic replacement.
- Existing final integration review independently exercised overlapping refresh, cancellation with Stop watching, failed scan releasing waiters, and rename-to-shared-save. Repeating these tests without new relevant code is not useful missing coverage.
- Installed-app success described in the ledger is bounded to one Staging process on this Mac: workspace setup, task write, shared comment Enter submission, relaunch/bookmark restoration. Root has newer sidebar/multiline-comment/Copy-content/external-change evidence to append.

## Highest-value remaining local checks

1. **Dirty selection → modal → Keep private:** native helper test does not display NSAlert and cannot prove pending selection survives native modal focus. Root reproduced a possible empty result. Separate owner is fixing; require actual private record and source/shared-record non-mutation, not merely closing the dialog.
2. **Installed source-conflict recovery interaction:** core/controller tests are strong, but actual Compare versions, preserve draft, export recovery, explicit all-head resolution, late-branch reopening and close/quit behavior are not visually accepted. Use a disposable document and independently injected valid records, retaining exact before/after hashes.
3. **Installed task conflict/read-state journey:** native tests cover contrary Done/Reopen and independent unread state; one actual app checkbox is not the full UI. Confirm conflicts expose a reachable explicit resolution, viewing activity does not resolve tasks, and named attribution is shown in narrow sidebar.
4. **Installed anchor drift:** deletion/repetition/insertion has core/task and renderer tests, but no visual proof that orphaned comments clearly require reattachment and cannot jump to an unrelated repeated passage. This matters for agent-written files that change externally.
5. **Light appearance, keyboard navigation, sidebar scroll reachability:** corrected narrow dark layout and multiline comment need evidence ledger updates. Actual VoiceOver and real IME input remain separate gaps; synthetic composition tests are not a real input-method test.
6. **Provider blocking during Stop watching/quit:** worker cancellation deliberately cannot interrupt a synchronous provider read. Local injected cancellation tests are bounded success evidence, not cloud placeholder/hydration proof. Do not induce real account/network disruption just to exercise it.

## Known failed target

- Reconcile at 2,000 events takes about 5.6–6.5 seconds in debug local storage tests; the two-second high-volume target is not met. At 1,000 events cold scans are about 2.4 seconds. No release-build/UI interaction latency measurement exists. Record as a measured performance limitation, not a failed correctness assertion or proven UI freeze.

## Necessarily distinct from local verification

- Christian's actual installed build/digest and identity; real two-Mac receipt/authorship/replies.
- OneDrive Files On-Demand hydration, real network offline/reconnect, provider conflict copies/ordering and account permission revocation.
- Actual simultaneous independent-Mac source saves and exact recovery on both machines.
- Gatekeeper/notarized artifact behavior on another Mac. Current Staging is Developer ID signed but not notarized.

## Evidence bookkeeping to correct

`ACCEPTANCE.md` opens with stale NOT RUN statements and a 203-test/build0602 section, then later contradicts them with actual local evidence. `COMPREHENSIVE-LOCAL.md` still says full suites, installation and corrected sidebar pending. Replace the summary with current dated build/commit-scoped results; retain historical evidence labelled historical. Do not convert the entire two-Mac acceptance matrix to PASS.

Separately, the user's responsive-table ticket remains unchecked in `docs/DEVELOPMENT-TICKETS.md` ticket 9. Collaboration acceptance must not be presented as completing that request. No change or new table implementation was audited here.

No additional existing test was run: all identified high-risk local gaps require actual UI/provider evidence or new regressions owned elsewhere; rerunning the existing green suite would not close them.
