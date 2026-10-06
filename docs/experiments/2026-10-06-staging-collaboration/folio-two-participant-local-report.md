# Fresh local two-participant collaboration integration

User requested testing here on the same setup. Added one permanent focused native XCTest in `/Users/philip.scholl/_WORK/markdown-reader/Tests/MarkdownReaderTests/CollaborationLocalIntegrationTests.swift`: `testTwoLocalParticipantsReviewTasksRestartAndRecoverCompetingEdits`.

Fresh final result: **1/1 passed**, 2026-10-06 17:19:08 local clock, 2.250 seconds. Log `/private/tmp/folio-two-participant-local-final.log`; no compiler warning/error. First complete run also passed in 2.184 seconds before removing a test-only async enumerator warning.

The actual Coordinator/ReaderCore implementation ran against one newly created disposable local shared folder and two separate disposable local participant stores named Pippo and Christian. User's installed app metadata and existing documents were untouched. No product code changed; no commits.

Verified in one connected journey:

- Workspace create/register and second-participant join/Open/select use the same document/workspace IDs; separate participant/device IDs and retained display names.
- Shared highlight, Pippo's comment and Christian's reply appear to both participants; correct reply-to message linkage and distinct authors survive delivery.
- Shared task registration, Christian's done status, then actual guarded Coordinator save with task trigger update the Markdown checkbox; Pippo receives the done state and sees Markdown aligned. Thread resolution stays independent.
- Private HighlightStore marks exist only in Pippo's local store, are absent in Christian's store, are excluded from shared feedback, and their private sentinel appears in none of the shared metadata/snapshot files.
- Marking the thread read locally does not change the other participant's unread/seen state.
- Two competing exact drafts are prepared durably from one current baseline using the same core prepare/apply/publish stages used by Coordinator.save, before either intent is delivered. First draft applies; second reports compare conflict without replacing the first. Both source heads reach both Coordinators and the second exact draft stays durable.
- Both Coordinators are recreated/restored from their local records. Profile IDs/names, full event IDs, comments/reply/task and both source heads survive. Coordinator recovery export after restore contains both exact draft byte sequences and coverage.json; source remains the first successfully applied draft. Private marks remain separate.

The test models restart by recreating local Coordinator/store instances in the same process, not relaunching the installed app. The competing prepare-before-delivery order is deterministic local staged delivery; it is not proof of network/provider timing. This provides fresh native local filesystem/API evidence on this Mac. Installed Staging UI validation is parent-owned. It does not claim two physical Macs, OneDrive synchronization/Files On-Demand or cloud acknowledgement.
