# Folio Staging collaboration acceptance

Status: implementation and independent slice/final reviews complete; all final automated checks passed; Developer ID signed preview built and installed locally. No visual-app or two-Mac acceptance claimed.

## Evidence boundaries

- Basic OneDrive delivery in both directions previously verified with a disposable Markdown file.
- Reviewed schema-1 CLI simulation: 28 tests. This is not app integration proof.
- New schema-2 integration, actual Staging permission/bookmark behavior, provider fault cases and simultaneous saves: NOT RUN.
- Public Folio, release feeds and Homebrew are outside this implementation scope.

## Actual-app checks

Use a fresh disposable child of the already shared MD-Sharing folder. Preserve existing documents. Philip creates the workspace once; Christian joins the same workspace after OneDrive delivery. Record identical Staging build/digest on both Macs.

| Check | Result | Evidence |
|---|---|---|
| Choose name/folder, relaunch, restore permission | NOT RUN | |
| Private marks remain private after joining | NOT RUN | |
| Shared highlight/comment/reply displays both authors | NOT RUN | |
| Passage insertion/deletion/repetition preserves or flags anchor | NOT RUN | |
| Task progress, Done/Reopen conflict, explicit resolution | NOT RUN | |
| Activity/read does not resolve or change another reader's unread state | NOT RUN | |
| OneDrive offline/reconnect: exact union of 100 actions per Mac | NOT RUN | |
| Restart after local save/publication interruption | NOT RUN | |
| Simultaneous saved S0→SA/SB: recover exact S0/SA/SB on both Macs | NOT RUN | |
| Missing snapshots, late branch after resolution | NOT RUN | |
| Permission loss, cloud-only files, rename/copy identity | NOT RUN | |
| Light/dark, keyboard, VoiceOver, real IME, narrow view | NOT RUN | |
| Capacity limits and UI responsiveness at 200/1000/2000 events | NOT RUN | |
| Shared feedback export excludes private data and preserves original authors | NOT RUN | |
| Stop watching preserves shared files/local recovery | NOT RUN | |

Unverified or failed source recovery blocks accepting shared source saving. A selected visible Markdown winner is not conflict resolution. Local writes never imply remote receipt.

## Integrated automated verification

Final controller runs against frozen integrated source on 2026-10-06: `npm test` 57/57 passed; `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-system native --scratch-path /private/tmp/folio-collaboration-final-public` 203/203 passed; same command with separate final-staging scratch and `-Xswiftc -DFOLIO_STAGING` 203/203 passed, both exit 0 at 16:54:24. Logs `/private/tmp/folio-collaboration-final-{js,public,staging}.log`. These are local tests, not real provider delivery or signed-app permission proof.

The earlier 202-test runs failed the unchanged late-source-branch assertion. An overlapping-refresh regression reproduced the premature completion; the awaited refresh barrier fixed it. The 203-test results above supersede those failed runs. Independent final review probes passed 5/5, including rename recovery, overlapping refresh, cancellation/shutdown and scan failure. See [final integration review](final-integration-review.md).

CUA could not initialize: the host rejects selected workspace path `[PP] Folio - The Markdown Reader` as a filesystem glob with write permission. No configuration changed to work around this; visual walkthrough remains NOT RUN.


## Local preview artifact

- Folio Staging 0.14.0 (2026100602), built from implementation commit `5b08a26`.
- Existing installation replaced at `~/Applications/Folio Staging.app`; public Folio unchanged.
- Build and installed bundle passed `codesign --verify --deep --strict`.
- Archive: `dist/Folio-Staging-0.14.0-2026100602.zip`.
- Archive SHA-256: `7d001b47718e0d8e22e1c0beccfe54f82a27c7983e55877459d77feedc0437d1`.
- Developer ID signed, **not notarized**. No public upload, release feed or Homebrew change. Christian installation/digest match remains NOT RUN.
- Launch requested through macOS `open`; no visual walkthrough claimed.
- Fresh disposable `Folio-Staging-Pilot-20261006/fixture.md` created inside Philip's approved MD-Sharing folder. Only the test document was written; workspace metadata and claimed identities must be initialized through the actual apps. Existing pilots preserved.

Start: Philip chooses **Add shared folder… → Create once** and selects that fresh pilot folder. Christian chooses **Join existing** in his synchronized copy after the review metadata arrives. Do not create a second workspace. Share `fixture.md` from the folder sheet and open it from the shared sidebar. Keep guarded source saves off until starting the disposable source-conflict test.
