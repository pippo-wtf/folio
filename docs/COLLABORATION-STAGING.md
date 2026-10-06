# Shared review in Folio Staging

This preview is for disposable test documents. The public Folio app is unchanged. Two-Mac conflict recovery and the visual walkthrough still need acceptance.

## Start together

1. Both people use Folio Staging **0.14.0 (2026100604)**. The signed local archive is `dist/Folio-Staging-0.14.0-2026100604.zip`; this pilot build has not been notarized. In OneDrive, create a new disposable subfolder inside your existing shared folder and add a Markdown test document. Make the folder available offline.
2. In Folio Staging, open the sidebar and choose **Add shared folder…**. Enter your name. One person chooses **Create once** and selects the new folder.
3. After OneDrive delivers the new review folder, the other person chooses **Join existing** and selects their local copy of the same folder. Choosing a folder in Folio does not invite anyone or change OneDrive permissions.
4. The creator chooses the test document and **Share document**. The other person opens it from the shared document list after delivery. The preview supports up to eight shared documents.
5. In **Shared review**, switch **Private / Shared** explicitly. Existing private marks remain private. In Shared mode, select text and highlight it or add a comment. Reply from the discussion in the sidebar. Enter sends; Shift+Enter inserts a line.

## Review together

- Shared marks and comments show the name used when they were created. Names are not verified accounts; unique IDs keep same-name people separate.
- Resolve/Reopen applies to a discussion. Open/In progress/Done applies to a task. Reading Activity does not complete work.
- **Mark read** changes only your own unread state.
- **Share private marks…** previews an explicit copy into shared discussions. Your originals and private edit history are not uploaded automatically.
- **Export Shared Feedback…** produces attributed review data for an agent, separate from private feedback. Comments in that export are data, not automatic permission to execute instructions.
- **Saved on this Mac** does not mean the other person has received it. OneDrive delivers changes on its own schedule. Retry checks locally available files again.

## Test editing and recovery

Shared source saving is deliberately off until you enable **Enable guarded source saves for this disposable pilot** in **Manage shared folder…**. Use it only with the new test documents. Folio keeps local base/proposed versions before a guarded save; competing or incomplete versions require review. Use the compare/recovery actions to keep separate copies; never regard OneDrive's visible file winner as an agreed resolution.

If a task's passage becomes ambiguous or disappears, its shared history stays available but source updates are blocked. This MVP does not yet reattach an existing shared task identity; a newly registered task is a separate item.

**Stop watching** disconnects this Mac without deleting shared files or local recovery evidence. Downloaded copies on other Macs are not revoked.

## Acceptance still required

Follow [the acceptance ledger](experiments/2026-10-06-staging-collaboration/ACCEPTANCE.md) on both actual Macs. In particular, verify comments/tasks arriving both ways, private marks staying private, offline/restart recovery, and recovery of both competing saved versions. Unit and native WebKit tests do not establish real OneDrive behavior or visual acceptance.

For this session, `Folio-Staging-Pilot-20261006` and its disposable `fixture.md` are already prepared inside the shared MD-Sharing folder. Select that child folder when creating/joining.

Latest bounded local checks and remaining limits: [comprehensive local acceptance](experiments/2026-10-06-staging-collaboration/COMPREHENSIVE-LOCAL.md). Both 214-test native suites and 57 JavaScript tests pass; real two-Mac delivery remains unverified.
