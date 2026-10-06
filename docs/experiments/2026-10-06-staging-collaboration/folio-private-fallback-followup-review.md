# Private fallback follow-up review — 2026-10-06

Read-only narrow review. **No blocking correctness findings.** Actual installed modal/private-record persistence remains controller-owned; supplied test results were not rerun by this reviewer.

The selection is captured through `sharedSelection` before NSAlert focus changes. `evaluateReview` independently verifies document identity, render token and current shared document before invoking the callback. The caller also checks captured source text before presenting the modal and checks source text, shared document and token after the modal closes. Save first continues through the existing guarded shared-save route; Keep private passes the captured selection to the renderer. Cancel performs neither operation.

`keepSelectionPrivate` validates both tokens and reconstructs the exact anchored quote and 64-character prefix/suffix at the original UTF-16 position. Shared and private tree walkers use the same exclusions and rendered-text coordinate space. Changed or stale passages return without publication. Accepted selections enter the existing private mark merge/save path, whose native receiver verifies current highlight token and persists draft state. This change does not save or modify document text and does not publish shared events.

The strengthened regression clears the live DOM selection before invoking the fallback, then verifies exact private mark, current draft revision, durable private record, unchanged disk source, retained dirty state and no shared annotations. Additional regression rejects stale token, changed passage and rerender. It does not present NSAlert, so installed-app focus behavior still needs real verification.

Non-blocking evidence caution: the native mode switches to private before renderer acceptance, and the renderer's true result denotes dispatch, not durable save. Neither a closed modal nor a Private segment alone proves a mark persisted. Verify the actual private JSON/visible mark, as controller is doing.

Reviewed SHA-256:
- ReaderModel+SharedReview.swift: 2e87634349409f107d1db149c27a9e501e7bf8e7f36fcea026b21f6586f59e72
- web/highlights.js: 2fd318305f0adfa3a188bb98315d8054ae078d5a8231e87a2530b553269421b5
- web/reader.js: 90020f16cb149ad68f3babf1cdd619ff10c71cb7f428440e58c7734198c5356f
- CollaborationPopoverAcceptanceTests.swift: b9819f7c3352c00cbd75c7fc56f57c2085bd59117c8f596302e2d67dae046fd5
