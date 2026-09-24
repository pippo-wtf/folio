# Local source edit journal

`EditJournalStore` records accepted transitions of the decoded Markdown source. It is local application data in a path-hashed JSON file; it does not write into the document folder or contact a network service. Its events are distinct from `HighlightStore` annotations. A highlight still means attention only; a nonempty `SavedHighlight.comment` is the explicit user feedback.

ReaderModel now records rendered edits and source typing after a 500 ms pause, flushes pending text on source exit, save, export, undo/redo and navigation, and records clean external reloads as exact changes. Editable Welcome text uses a private draft key until Save As. A journal failure is shown in the app but does not prevent saving the Markdown file, undoing, reloading, or leaving the document.

## Event contract

- `kind`: `renderedEdit`, `sourceEdit`, `undo`, `redo`, `save`, or `externalReload`. `externalReload` means unknown external authorship, not a Folio user edit.
- `beforeRevision` and `afterRevision`: SHA-256 of the **decoded source encoded as UTF-8**. These differ from raw file-byte hashes when the source file uses UTF-16 or a BOM.
- `replacement.offsetUTF8`: zero-based byte offset in the before revision's decoded UTF-8 source. `oldText` and `newText` are exact strings. An insertion has empty `oldText`; a deletion has empty `newText`. A save checkpoint with no text change has no replacement.
- `id`, `sequence`, `date`, and `updatedAt`: stable event identity, journal order, first edit time, and latest coalesced edit time.

`EditJournalStore.replay(event:on:)` checks the complete before hash, exact replaced bytes, and complete after hash. Reverse replay checks the inverse. Consumers must never apply a replacement solely from its offset or quote. For external file changes, replay is useful as a comparison but does not prove who wrote it.

On reopening a document, compare the persisted journal head with the freshly decoded source. Call `recordExternalGap(for:observedText:)` before recording any new local edit. If the hashes differ, it appends an `externalReload` event with `gapReason: "source-before-unavailable"`, the two hashes, and no replacement. This event cannot be replayed because Folio did not retain the previous full source. It must be shown as an external history gap, never an invented exact change. When there is no prior journal, the same call establishes the first baseline without an event.

## Model integration

Create the store in Application Support under the active build channel, for example `.../Folio/EditJournal`. Use the same canonical document key as `HighlightStore`. Make journal failure visible and keep the document/draft available; a corrupt or full journal is never silently reset.

Call `record(for:from:to:kind:)` at these boundaries:

| Boundary | `from` | `to` | Kind |
| --- | --- | --- | --- |
| Accepted rendered edit | current source immediately before the accepted replacement | accepted source | `renderedEdit` |
| Source editor exit or debounced stable edit | source at entry or previous recorded state | current source | `sourceEdit` |
| Page or source undo/redo | source just before the undo/redo | restored source | `undo` / `redo` |
| Successful save | latest journaled source (or pre-save source if no journal exists) | saved decoded source | `save` |
| Clean external reload while Folio is open | previously displayed source | newly loaded decoded source | `externalReload` |

If rendered edits are recorded on every accepted change, pass `coalesceRenderedEdits: true`; adjacent changes within 0.7 seconds merge into one net replacement and retain the first event ID. Debouncing before journal writes is preferable for disk load. Source typing should be recorded on source editor exit, a stable debounce, and before save/export/navigation so each edit is captured without writing a full event for every keystroke. When recording at both a debounce and source exit, pass the journal's last recorded source as `from`; no-op transitions are ignored. On save, a same-revision checkpoint records the save action without duplicating the text edit. If the journal head does not match the supplied preimage, stop and surface `revisionMismatch`; never skip the gap.

After a successful Save As to a new path, call `copyIfAbsent(from:to:)` with the old and new document keys, then record the save checkpoint against the new key. This copies history only when the destination has no journal. If a destination journal already exists, retain it and reconcile its head with the newly saved source; do not overwrite another document's feedback history.

Export preserves the existing `HighlightStore.feedback` fields and appends the loaded journal as top-level `sourceEdits`. Its offsets and hashes have the labels above. The export remains a copy; reading or exporting it does not acknowledge or resolve feedback. Folio flushes a pending transition before export or marks the packet incomplete. Existing annotation JSON stays readable, and its rendered UTF-16 anchors are not converted into source offsets.

Folio exports `sourceEdits`, `journalComplete`, and `currentTextUnjournaled` alongside the original annotation packet fields. When a journal is full, export can still copy its existing bounded history with `journalComplete: false`; the current editor text remains available and the app warns that it is missing from that history. The user can then choose **Clear Exported Edit History…**. Clearing a readable journal with events requires a successful export of that exact journal state and a confirmation. A damaged journal cannot be exported; clearing it requires a separate explicit confirmation that names the loss. After clearing, Folio records any still available text transition from its cached last journaled source as `unrecordedTransition`.

The journal limits are 8 MiB decoded UTF-8 source per transition, 512 events, and 32 MiB serialized JSON. The store throws a specific error at the limit and preserves the previous file. `clear(for:)` is an explicit post-export discard operation; no automatic pruning or recovery silently loses history. The file is written atomically, and malformed or unsupported files are left untouched.
