# Folio: shared review and Copy content

Date: 6 October 2026
Status: research and proposed tickets for discussion; no implementation authorized or started.

## Intended outcome

Two creatives can review the same Markdown document, highlight passages, leave comments, and see who completed a task. Their contributions survive restarts and delayed synchronization. The reading surface stays quiet. Add a top-right **Copy content** button.

Explicit requests: simple identity; collaborative work; synchronization after meaningful actions rather than live keystrokes; visible activity/completion; potentially watch a selected OneDrive folder; user flow; technology research; tickets.

Assumptions for this draft: two trusted collaborators on Macs; both already have access to the same OneDrive folder; asynchronous review first; original Markdown remains portable; no new Folio account or hosted service for this first scope. Confirmed by Pippo: shared review first; text edits are saved and synced with conflict protection. Simultaneous free-form text merging is outside v1. Copy content means copying the whole current Markdown source, including unsaved edits, ready for an agent; existing formatted-copy behavior remains separate.

Scope decision received: shared review first, with saved text changes and conflict protection. Option A is the proposed foundation, subject to the two-Mac reliability experiment. Live concurrent text merging is deferred; option C remains a future alternative.

## Verified existing foundation

Inspected the clean source checkout at `/Users/philip.scholl/_WORK/markdown-reader`. The currently selected workspace `/Users/philip.scholl/_WORK/[PP] Folio - The Markdown Reader` is empty; this proposal is saved in the actual source checkout. Do not relocate the app as part of this feature.

- Swift macOS shell with WKWebView and a custom JavaScript renderer/editor; no ProseMirror/Yjs editor dependency in package.json.
- `ReaderModel.startMonitor()` checks the open file's modification date and size once per second. It is not a watched-folder browser or remote collaboration service.
- `DocumentSnapshot.save` compares original bytes before an atomic local save. Dirty external changes produce a conflict warning; this does not establish a cross-device lock or cloud transaction.
- `HighlightStore` stores highlights, a single optional comment per highlight, revision and local events in application data keyed by a hash of the document path. There is no author or resolved state. Absolute paths differ across users.
- `EditJournalStore` already records local source changes and exports feedback for agents. Imported changes must not be misattributed as local changes.
- `copyFormatted` already exists. The new top-right whole-document button must have explicit behavior rather than silently changing selection-copy semantics.

## Technology research and options

### A. Shared folder + Folio review events — recommended for asynchronous review

OneDrive remains responsible for access and transporting files. Folio watches a folder the user explicitly chooses, exchanges small review-event files alongside the Markdown, and reconstructs a shared review state locally. Entering a name is a profile, not authenticated login. Anybody with write access to the folder can alter shared data; this is suitable for a trusted team, not an audited identity system.

Use native Foundation file coordination/presentation and folder notifications, with reconciliation scans. Apple documents that file presenters coordinate file/directory access, and that FSEvents may coalesce/drop events and require recursive rescans. These are local filesystem mechanisms, not proof that another Mac received a change. [Apple file presenters](https://developer.apple.com/documentation/foundation/nsfilepresenter), [Apple FSEvents guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html).

OneDrive Files On-Demand means a visible file can require downloading. Ask users to make the shared folder available offline and still handle unavailable items, paused sync and missing permission. Ordinary Markdown synchronization should not be confused with Office coauthoring; Microsoft's supported Office formats do not include `.md`. [Microsoft Files On-Demand](https://support.microsoft.com/en-au/onedrive/save-disk-space-with-onedrive-files-on-demand-for-mac), [Microsoft coauthoring](https://support.microsoft.com/en-gb/office/troubleshoot-co-authoring-in-office).

Pros: no Folio server/account/subscription; matches existing local files. Costs: cloud delivery delay, uncertain remote sync state, trust-based names, robust event reconciliation and conflict UX. Native file access is reusable for other sync providers, but v1 qualification is OneDrive only.

### B. Microsoft sign-in + direct Graph integration

MSAL supplies Microsoft account sign-in. Graph delta queries track remote additions/changes/deletions through paginated results and continuation tokens; they are not a keystroke stream. Upload sessions document `if-match` preconditions and 412 responses. A direct integration still needs explicit reconciliation, account/tenant permissions and validation of upload-session races; do not assume local OneDrive writes and Graph writes are interchangeable.

[MSAL](https://learn.microsoft.com/en-us/entra/msal/objc/single-sign-on-macos-ios), [Graph delta](https://learn.microsoft.com/en-us/graph/api/driveitem-delta?view=graph-rest-1.0), [Graph upload sessions](https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession?view=graph-rest-1.0).

Pros: verified Microsoft identity and better server visibility. Costs: app registration, account consent, possible employer restrictions, more integration surface. Shared-folder permissions and OneDrive Personal versus Business must be tested. Not the default for a name-only trusted review feature.

### C. Dedicated collaboration engine + authenticated service

Yjs supplies shared data structures and editor bindings; its awareness protocol supplies transient presence. Automerge supplies a mergeable document model and repository storage/network adapters. Neither automatically upgrades Folio's custom source-preserving editor or makes external OneDrive rewrites merge safely. A prototype must prove Markdown round-tripping, anchors, undo and offline recovery before selecting either.

[Yjs introduction](https://docs.yjs.dev/), [Yjs presence](https://docs.yjs.dev/getting-started/adding-awareness), [Automerge repositories](https://automerge.org/docs/reference/repositories/).

Pros: best direction if overlapping text edits and actual presence are essential. Costs: identity, hosting/operations, access control and a difficult editor integration. Railway could host a service, but this proposal creates no service and makes no unverified cost promise. OneDrive should be an import/export boundary with explicit conflict handling, not a second independent authority rewriting live collaborative content.

## Proposed v1 user flow

1. **Join a shared folder.** Sidebar offers “Add shared folder…”. Choose an already-shared local OneDrive folder. Folio explains that review data will be shared with everyone who has folder access. Choosing the folder does not invite people or grant permissions.
2. **Introduce yourself.** Enter a display name once. Folio generates a stable random participant ID and a separate device ID. Two people named Alex remain distinct. No email or password. Existing solo use never requires this step.
3. **Open a document.** Sidebar lists Markdown files and an unread-activity indicator. Main page uses existing Green Line light/dark styling. A small status says “Checked this folder just now”, never “Everyone is up to date” without evidence.
4. **Review together.** Select a passage and use Highlight or Comment. Comments show author/time and replies. Shared highlights carry author labels in the review panel. Existing private marks stay private until explicitly shared.
5. **Complete work.** Comments can be resolved and reopened. Tasks have Open, In progress and Done; each transition records its author. For Markdown checkbox tasks, shared review state is persisted first, and applying it to the source is a separately guarded operation. A failed source update remains visibly pending. A checkbox and its shared status must never silently disagree.
6. **See what changed.** Activity shows “Maya commented on …”, “Pippo marked … done”, and “Maya reopened …”. Clicking jumps to the passage; ambiguous/deleted passages show “Passage changed” and retain the comment for reattachment. Reading an item only clears that person's unread flag; it does not resolve it.
7. **Handle delayed delivery.** Local actions appear immediately and survive offline use. “Saved on this Mac · OneDrive handles sharing” describes the actual guarantee. Once a remote event arrives locally, Folio refreshes it without forcing a document reload or losing a selection/draft.
8. **Editing text.** Save a local draft; if an external revision arrives, preserve both and offer Compare / Keep a separate copy. Both people can save text changes. Before publishing a save, Folio preserves its base and proposed source revision in the shared recovery protocol. If concurrent source revisions branch from the same baseline, keep both and show a conflict even if OneDrive has already selected a current `.md` copy. Do not silently merge overlapping changes. “In progress” is an advisory work state, not a lock. The two-Mac experiment must prove this recovery workflow before release; otherwise fall back to review-only or reconsider the transport.
9. **Copy content.** Persistent top-right button labeled exactly “Copy content”. Copies the whole current Markdown source, including checkbox states and unsaved text, regardless of selection or scroll. Brief “Copied” confirmation. No comments, activity history or hidden metadata added to copied text. Agent feedback retains its own export action.
10. **Leave.** Stop watching removes local access/bookmark/watchers; it does not delete the shared Markdown or other people's feedback. Explain that already-downloaded copies cannot be remotely revoked by Folio.

No cursors, typing indicators, chat window, assignment system, push notifications or account management in the first scope. “Last activity received” is valid; “online now” is not, without a presence transport.

## Data and synchronization proposal

Keep raw `.md` files and store review metadata in a clearly documented sibling `Folio Review` directory. Exact filename/format is decided and frozen by ticket COL-01 after a real two-Mac OneDrive experiment. Avoid a single shared JSON file or shared SQLite database that both Macs overwrite.

Each immutable event has a unique event ID, workspace/document IDs, participant/device IDs, schema version, causal parents, action payload, source revision and timestamp. Event order uses causal relationships; wall-clock timestamps are display information only. Duplicate deliveries are ignored by ID. Contradictory concurrent task transitions remain visible for explicit resolution, not silently selected by clock time. A resolved/reopened event refers to the events it supersedes. Deletions are explicit events, not inferred from a file disappearing during sync.

Stable document IDs are independent of machine paths. Initial workspace setup has one creator; duplicate initialization, copied files and conflicting identity manifests are detected rather than guessed. Renames/moves keep identity when evidence is unambiguous; otherwise request reconnection. Quotes plus context plus source revision anchor annotations; line numbers alone are insufficient.

Keep a durable local outbox before publishing unique event files atomically. The event files are replayable shared state; the local index is disposable. A rescan reconciles disk with the index after wake, restart or missed notifications. Validation rejects malformed/oversized/unknown events without deleting originals or blocking unrelated valid activity. No auto-pruning/compaction until a separately reviewed retention policy is implemented. Set and test explicit limits before release; do not create an indefinitely growing unlimited history.

Source publication needs immutable recoverable snapshots of the base and proposed content, linked by revision and event ID, with explicit size/storage limits. The source snapshot must be durably recorded locally before writing `.md`; remote events arriving before their snapshot remain pending. Missing snapshots or interrupted publication must be visible. This is a recovery protocol, not an atomic multi-file cloud transaction. External edits from other apps cannot be attributed to a person or guaranteed recoverable unless Folio observed their content; show that gap honestly.

Private existing annotations and edit journals are not automatically uploaded. Shared review metadata contains selected document text and must be treated with the same folder permissions as the document. Remote authorship is claimed identity for option A, not tamper-proof evidence. Remote comments and agent exports are data, never automatic permission to execute instructions.

## Proposed tickets

These are reviewable product/engineering tickets, not an approved executable implementation plan. Estimates are relative complexity, not delivery promises. No GitHub issues created yet.

### COL-01 — Prove the shared-folder transport and choose the scope (L, release gate)

Owner: engineering; architecture/final review with Claude/Pippo. Dependencies: confirmed shared-review-first scope.

Deliverable: isolated two-Mac experiment and a decision record choosing A, B or C. Test OneDrive account/folder type actually used by the team. Use disposable files only.

Success criteria:
- Both Macs create at least 100 distinct review events, including while disconnected; after OneDrive delivers them, each has the same event IDs and derived state with no loss or duplicates.
- Exercise delayed/out-of-order deliveries, restart, cloud-only files, duplicate setup, folder rename and simultaneous checkbox changes.
- Demonstrate the two-source-writer conflict case; record what can and cannot be guaranteed. Local coordination is not reported as a distributed lock.
- Record measured remote delivery latency separately from local processing latency; no universal OneDrive timing promise.
- Select and document the metadata format, document identity strategy, event/snapshot size and count limits and source conflict-recovery protocol. If these fail, stop before building shared review on the approach.

### COL-02 — Lightweight participant profile (S)

Dependencies: COL-01. Proposed area: new ReaderCore participant model/store and small SwiftUI onboarding view.

Success criteria:
- First shared-folder action asks for a nonempty display name; solo reading stays account-free.
- Stable participant ID survives relaunch; device ID is separate; identical names do not merge contributions.
- Renaming a profile does not reassign old events; imported actor IDs remain distinct.
- UI clearly describes a shared-folder profile, not authenticated Microsoft login.

### COL-03 — Choose and watch a shared folder (M)

Dependencies: COL-01. Proposed area: native shared-folder store/watcher, sidebar integration, ReaderModel integration.

Success criteria:
- User-selected folder permission persists through supported security-scoped bookmarks and can be removed/reconnected.
- Initial scan and subsequent reconciliation find nested Markdown additions, changes, moves and removals within the selected boundary; symlinks do not escape it.
- Tests cover event coalescing/loss, atomic file replacement, wake and relaunch. No per-file one-second polling loop across the whole folder.
- When cloud content is unavailable, preserve the last readable version and show a useful retry state; folder loss never erases annotations.
- No claim of remote synchronization based solely on a local filesystem write.

### COL-04 — Durable shared review events and reconciliation (L)

Dependencies: COL-01–03. Proposed area: new ReaderCore event schema, outbox and reducer; shared-folder adapter.

Success criteria:
- Immutable uniquely named events and a durable outbox survive interruption between local save and shared-folder publication.
- Replay is idempotent and converges regardless of delivery order; missing causal parents remain pending until available.
- Simultaneous comments survive; contradictory status changes surface a resolvable conflict with both authors.
- Malformed, oversized and unsupported-version files produce bounded diagnostics; valid sibling events still import.
- Enforce COL-01 limits with visible recovery/export behavior; do not silently discard history.

### COL-05 — Share highlights and threaded comments (M)

Dependencies: COL-04. Existing areas: HighlightStore, CommentComposer, web/highlight-anchors.js; add adapter rather than changing private storage into shared storage wholesale.

Success criteria:
- Both participants see each other's explicitly shared highlights/comments and can reply after delivery.
- Existing private highlights are not shared by joining a folder; migration is an explicit per-document choice.
- Author and timestamp are visible in the review panel; hover/click ties a mark to the correct discussion.
- A paragraph insertion retains an unambiguous anchor; repeated quotes/deleted passages never attach silently to the wrong text.
- Existing Enter-to-submit / Shift+Enter-newline and light/dark design behavior remain intact.

### COL-06 — Task status, resolve and reopen (M)

Dependencies: COL-04, COL-05, COL-08 source policy. Existing areas: TaskListEdit, ReaderModel; new shared review state.

Success criteria:
- Open → In progress → Done and reopen actions are attributed and appear on both Macs after delivery.
- Resolve/reopen comments is separate from task checkbox status and unread state.
- A checkbox update targets a stable/unambiguous task in the expected revision; duplicate labels or modified source require review.
- Shared status and `.md` checkbox state have a defined, tested reconciliation rule; pending/conflicted source application is visible and never presented as completed file synchronization.
- Simultaneous Done/Reopen preserves both actions and has a deterministic explicit-resolution path.

### COL-07 — Activity and unread review sidebar (M)

Dependencies: COL-05–06. Proposed area: native review/activity view and local per-user read cursors.

Success criteria:
- Sidebar groups Open, Done and Activity with clear author/action/time and a two-line passage preview.
- Clicking jumps to the correct anchored text or exposes the missing-anchor state.
- Received actions become visible within 2 seconds of being validated locally under the agreed pilot-size limit; external OneDrive delivery time is measured separately.
- Reading does not mark work done; each participant's unread state is independent.
- Labels distinguish local save, local folder refresh and received remote activity; no false live-presence badge.

### COL-08 — Protect drafts and define source publication (L, release gate)

Dependencies: COL-01, COL-03–04. Existing areas: DocumentSnapshot, DraftStore, ReaderModel reload/save, TaskListEdit.

Success criteria:
- External revision during unsaved edits never replaces the draft; original/baseline, local and incoming versions remain recoverable.
- Same-size/same-timestamp replacement is caught by reconciliation/content checks rather than metadata polling alone.
- Each Folio source save retains recoverable base/proposed snapshots before changing the original; interrupted/reordered snapshot and event publication is tested. Advisory markers are never called locks. Document external-editor limitations explicitly.
- Concurrent cross-device saves produce a visible conflict with both full versions recoverable after delivery, including when OneDrive replaces one `.md` version. Otherwise shared source editing is disabled, not shipped with a “no lost edits” claim.
- Encoding/BOM, line endings and untouched Markdown survive saves; checkbox changes and agent-driven external edits use the same protection.

### COL-09 — Agent feedback knows author and review state (M)

Dependencies: COL-04–06, COL-08. Existing areas: HighlightStore.feedback, EditJournalStore, docs/EDIT-JOURNAL.md.

Success criteria:
- Export includes document identity/revision, event IDs, author identity, comments and task/review status; private data appears only through existing explicit export choices.
- Received events retain original provenance and are not echoed back as fresh local events.
- Repeated import/export does not multiply changes; deleted or ambiguous passages remain visibly unresolved.
- Exporting or an agent reading feedback never acknowledges/resolves tasks automatically.
- Existing feedback consumers get a versioned migration path and fixtures; local journals are not silently rewritten as shared history.

### COL-10 — Top-right “Copy content” button (S, independent)

Existing areas: ReaderView toolbar, ReaderModel editor synchronization and clipboard bridge.

Success criteria:
- Exact visible label “Copy content” at top right; follows both themes, keyboard navigation and narrow-window toolbar overflow.
- Copies entire current Markdown, not selected text or visible viewport; preserves lists, code fences, checkbox states and line breaks.
- Includes unsaved rendered/source edits after pending editor changes flush; never silently copies the previous revision.
- Does not save the file, resolve feedback, include private comments or alter formatting.
- “Copied” appears only after clipboard success; empty-document behavior is explicit and clipboard errors visible.
- Tests cover selection present, long/code-heavy document, source mode, unsaved rendered edit and IME composition. During active composition, defer copy until committed rather than lose input.

### COL-11 — Two-person reliability and usability acceptance (M, release gate)

Dependencies: COL-02–10.

Success criteria:
- Two creatives complete onboarding → shared highlight → reply → task Done → reopen → agent export with no developer tooling.
- Repeat across offline/reconnect, paused OneDrive, restart, deleted/renamed files, revoked folder access and conflicting drafts; compare final event IDs/state on both devices.
- Verify Green Line light/dark, large text, keyboard/VoiceOver access, stable scroll and no selection loss on incoming activity.
- Run existing Swift and JS suites plus new reducer/watcher tests; record actual two-Mac results, limits and measured timing in a release ledger.
- A failed transport/concurrency acceptance gate prevents public rollout of that capability.

### COL-12 — Documentation and staged rollout (S)

Dependencies: COL-11; COL-10 may release independently after its own tests.

Success criteria:
- Staging preview explains folder access, profile identity, metadata location, privacy scope, delivery limits, supported provider/account types and source-editing policy.
- User can stop watching without deleting shared files; recovery/export procedure is documented.
- Public release only after review; no sign-up requirement for solo users, no silent migration/upload of private annotations.
- Release process retains signed/notarized binaries and user-triggered installation; no automatic installer execution.

### COL-13 — Concurrent text-editing feasibility (conditional L)

Only activated if concurrent source editing is required; dependencies: scope decision. This replaces manual source-conflict review with a collaborative editing model; it is not a cosmetic add-on.

Success criteria:
- Compare a Yjs editor binding/integration against Automerge on an isolated branch with Folio's actual custom editing model and format fixtures.
- Two clients edit overlapping text and task checkboxes, go offline, reconnect, undo locally and converge without losing acknowledged operations.
- Untouched Markdown, complex blocks, comments and source-mode edits round-trip under a specified canonical model.
- Specify authentication/access revocation, durable service storage and the OneDrive import/export boundary; test external agent rewrites explicitly.
- Produce a revised design and separate implementation plan for approval; no server deployed or editor migration started from this ticket draft.

## Sequence and approval

1. Shared-review-first scope confirmed. Review proposed flow, transport and Copy content semantics with Pippo.
2. COL-10 is independent and can be planned/built first after approval.
3. COL-01 determines the collaboration foundation; COL-13 becomes mandatory if simultaneous source editing is required.
4. For option A: COL-02/03 → COL-04 → COL-05/08 → COL-06/07/09 → COL-11 → COL-12.
5. Superpowers architectural workflow: approve written design, then create a detailed implementation plan with exact interfaces/tests; select execution approach before implementation. Claude reviews architecture/frontend decisions; Codex implements code/tests/integration within the approved design.

No app code, dependencies, cloud resources or release feeds changed by this planning task.
