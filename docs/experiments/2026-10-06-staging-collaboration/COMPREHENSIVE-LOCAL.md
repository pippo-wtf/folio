# Comprehensive local acceptance — 2026-10-06

Latest tested local installation: Folio Staging 0.14.0 (2026100604), Developer ID signed, not notarized. Public Folio and release feeds unchanged.

## Verified

- Complete native suites: **214/214 public and 214/214 Staging**, zero failures, exit 0. JavaScript: **57/57**. Logs: `/private/tmp/folio-final-214-{public,staging}.log` and `/private/tmp/folio-private-modal-js.log`.
- Actual app: create workspace/name, register/open, shared/private choice, shared comment + Enter, Shift+Enter multiline comment, task checkbox persisted to Markdown, real quit/relaunch permission and document restoration, Copy content exact-byte equality.
- External labelled fixture change detected automatically; author shown unknown. Actual source comparison sheet opened and showed draft, observed file and recovery actions. Competing-version recovery through this UI remains unverified.
- Default 220-point sidebar now shows complete segmented controls, wrapping hints and a full multiline comment in Light and Dark appearances.
- Actual dirty Shared selection → Keep private: corrected dialog closes once, switches to Private, and writes the exact selected passage to private Highlights JSON with draft=true and the draft revision. Test paragraph was not saved to Markdown. The fixture was restored to its original saved text afterward.
- Actual disposable discussion resolved and appeared in Done with Reopen action. Reopen/task-conflict controls were not exercised end to end.
- Three isolated native replicas: 100 offline actions each, reversed delivery and duplicate files converge to exactly 300 unique events. Missing parent/snapshot delivery, restart, BOM/CRLF/emoji, 2000-event capacity and safe rejection at 2001 tested.
- Local two-person source conflict recovery, separate private/read state and attributed shared export covered by native integration tests; these do not prove remote provider behavior.

## Reproduced defects fixed

1. Sidebar clipping: hidden visual picker labels and local multiline sizing. Regression RED→GREEN; actual narrow Light/Dark visuals verified.
2. Keep private dialog loop: private intent no longer reenters shared action.
3. Follow-up actual-app defect: modal focus lost the selection, so no private mark was written despite the mode change. Capture the token-bound passage before the dialog; validate document/text/token afterward and exact quote/context in renderer. Lost-selection regression RED→GREEN; stale token, changed passage and rerender rejected. Actual private JSON verified on build 0604.

Independent review found no blocking issue in the narrow fix. Screenshots and reports in this directory preserve evidence; no private user documents included.

## Limits and failures retained

- High-volume performance target **NOT MET**. Isolated 2000-event reconciliation took about 5.6–6.1 seconds; loaded full-suite runs were slower (Staging cold 14.56, retained 6.42 seconds). No UI responsiveness claim follows from core timings.
- Second physical Mac/real OneDrive delivery, Files On-Demand, offline network recovery and simultaneous real-app saves remain unverified. Local simulations are not remote receipts.
- Real VoiceOver/IME, full keyboard navigation, all recovery/export dialogs and orphaned-anchor UX remain unverified. CUA initialization is blocked by the selected workspace path; native accessibility/pointer controls enabled the bounded actual-app checks, with stale AX sidebar trees cross-checked using screenshots and durable records.
- Shared source saving remains an explicitly enabled disposable-pilot feature. This is not a production collaboration release or completion of the responsive-table backlog.

## Artifact

`dist/Folio-Staging-0.14.0-2026100604.zip`

SHA-256: `efd88bcd9dcc190988058ce4c4b5448a57922945f28255ea80227887494032bc`

Installed bundle passed codesign --verify --deep --strict. Archive is local only; no GitHub upload, notarization, appcast or Homebrew update.
