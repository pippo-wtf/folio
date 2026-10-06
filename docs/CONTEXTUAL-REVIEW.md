# Contextual review in Folio Staging

2026-10-06 · Staging 0.14.0 (2026100606)

## Interaction

- Select a passage to choose Private or Shared beside the selection, then highlight or comment.
- Click a shared mark to open its discussion beside the passage. Reply, resolve and reopen there.
- Private comments use the same contextual input. Enter submits; Shift+Enter adds a line.
- Shared task status controls sit beside each checkbox. Open, In progress and Done are review states; applying a status to Markdown retains the existing source-save safeguards.
- The sidebar contains compact Open/Done/Activity lists, passage jumps, recovery actions and shared-folder settings.
- Panels use the current Folio theme tokens, flat controls and a single focus border. Review controls remain outside document content, so they do not change source text or highlight anchor offsets.

## Evidence

Verified in the installed Staging app against the disposable shared-folder pilot:

- A shared reply submitted beside its passage produced exactly one matching durable shared event.
- A private comment submitted with Enter persisted in local highlight storage, with no matching shared event or Markdown change.
- Task controls opened beside the checkbox; changing the review status preserved the guarded-source-save boundary.
- The sidebar showed summaries and jump links rather than embedded discussion composers.

Automated verification:

- JavaScript: 58 tests passed.
- Full native Staging suite: 224 tests passed, exit 0 (`/private/tmp/folio-context-harness-full-native.log`).
- Full native public-build suite: 227 tests executed, 1 focus-host skip, 0 failures, exit 0 (`/private/tmp/folio-context-public-final.log`).
- Additional WebKit regressions: selection/privacy echoes and dark/light palette checks passed. The separate focus-border check explicitly skipped because the test host could not acquire document focus; its focus assertions remain intact.
- Installed build signature verified with `codesign --verify --deep --strict`; installed CSS/JavaScript match the repository files.
- Earlier complete runs had intermittent WebKit startup failures before behavior assertions. A focused predecessor sequence (51 tests) and the subsequent full run passed without changing timeouts or assertions. The startup failure cause remains unproven.

This is a local Staging build. The public application and GitHub release were not replaced. The contextual UI checks here do not constitute a fresh second-Mac OneDrive acceptance run.
