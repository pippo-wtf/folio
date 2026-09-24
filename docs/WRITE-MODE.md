# Editing on the page — Folio 0.13.0 candidate

This describes the local 0.13.0 candidate under review. The public release remains 0.12.3.

The styled page is the default editor, with one continuous editing surface for ordinary text. Click a paragraph, heading, ordinary list or blockquote and type. The bottom bar provides Body, Heading 1/2, bulleted and numbered lists, Quote, Bold, Italic, Strike, Link and a word count. Oswald, Source Serif 4 and the saved preset remain in effect. A blank passage at the end allows continued writing. Click a link to edit its label and destination; Command-click follows it.

Fenced code blocks, simple pipe tables, and standalone local Markdown images have a small Edit control on the page. Code editing includes text and language. Table editing includes cells and row/column controls. Image editing includes alt text and a relative local path. Apply commits one undoable document edit; Cancel or Escape leaves the source untouched. The controls render the updated block immediately.

Source is an optional toolbar toggle for the full Markdown document. There is no separate Read/Write mode selector. New and recovered documents open on the styled page.

## Saving and preservation

- Command-S saves the original; Command-Shift-S saves a copy. Switching to Source does not save.
- The native model receives each passage edit and schedules local draft recovery. The edited title and save/discard/cancel safeguards apply to both views.
- Rich editing retains the original source of unchanged passages and complex blocks. Selections and replacements can span ordinary paragraphs, headings and lists. Untouched front matter, definitions and whitespace remain intact. Editing a complex block changes only its mapped source range. Edited passages and tables may normalize Markdown syntax; CRLF and surrounding blank lines are retained.
- Source edits retain the existing native editor. UTF-8/BOM and UTF-16 encoding safeguards, atomic save and external-change checks remain in place.
- Page Undo/Redo uses bounded local history (100 snapshots, 16 MB undo budget), grouping consecutive typing within 700 ms in the same passage. History is cleared on document changes. Switching back from Source records source changes as one page-undo step; earlier page history remains available. Source retains native text undo while open.
- Paste on the page inserts plain text. Clicking a link in an editable passage opens its label/destination controls; Command-click follows it. Only HTTP(S) external links open through the native link policy. Other destinations remain in Markdown source.

## Current scope

The page controls cover simple pipe tables up to 200 rows and 30 columns, closed fenced code with a simple language name, and standalone local Markdown images in the supported raster formats. Code text is limited to 1,000,000 characters and fence runs to 128 characters in the page control. Indented or unclosed code, tables with code-span pipes or malformed rows, image references or images mixed with paragraph text, equations, diagrams, callouts, footnotes, wiki links, hidden comments and other unsupported extensions still require Source. Paragraphs with reference links also use Source to avoid rewriting external definitions. A selection spanning a protected block still requires Source. Toolbar heading levels are 1/2; Source supports all six. Table cell fields contain Markdown cell text, so escaped pipes appear as `\|`.

Saved highlights remain local annotations. Changing or deleting a marked quote can leave a saved mark unresolved. There is no automatic publication or agent transmission.

## Verification

- 44 JavaScript tests passed after the complex-block hardening, covering targeted source replacement, CRLF/front matter/code/footnote preservation, link passage isolation, malformed-block fallback, local image paths, table alignment, heading collision allocation, protected syntax and escaping.
- Native checks on a temporary 0.13.0 candidate exercised code, table and image Apply, then Save and reopen. The edited values persisted, and the untouched source sentinel remained intact. Cancel left the code source unchanged. A table Undo restored the table while keeping a separate code edit.
- Native code-field typing preserved straight ASCII quotes. In test build 991005, Undo and Redo worked with the final simplified shortcut path. On the German keyboard layout, the test driver sends `super+y` for Command-Z. The word counter showed 53 before opening the code dialog, after Cancel and after Apply for the tested code change.
- Earlier continuous-editing smoke verified creating a document directly on the page, heading and bold formatting, paragraph creation, Source inspection, save to a temporary Markdown file and reopen.
- Native continuous-editing check: replaced two paragraphs with one, saved, verified exact unchanged front matter and code whitespace; Undo restored both paragraphs; Redo reapplied the replacement; a Source change was undone after returning to the page.
- Export PDF (Shift-Command-E) opens a save dialog and silently generates an A4 PDF. No Print action or printer controls. One-page and three-page exports were extracted and visually inspected; headings stayed with text and the saved highlight appeared.
- Native launch-recovery check in test build 991005 displayed the Recover/Discard prompt after killing the exact process with a disposable unsaved source edit. Recover opened the draft; Save used Save As to create a separate `Recovered-QA.md`, and the original file remained unchanged.
- The current 0.13.0 candidate has not been released. VoiceOver, input-method composition, narrow-window use, a clean-Mac install and near-limit performance remain unchecked.

Final native link check (991005): clicking an existing link opened label/destination controls; changing its label and applying updated the rendered link. Save wrote the exact new Markdown destination, retained code, Unicode and the recovered sentinel, and did not alter the original file.
