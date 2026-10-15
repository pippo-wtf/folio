# Table width correction

Installed locally in regular Folio 0.14.1, build 2026101501. Developer ID signed, Apple notarized and stapled. App, installer helper, nested payload and DMG pass Gatekeeper. Release receipt: `updates/release-0.14.1.json`.

The previous request existed only as backlog ticket 9. Shipped CSS restricted tables to 100% and used overflow:auto. Native WebKit reproduced a table wider than its visible wrapper.

Top-level table wrappers now expand to at most 125% of the reading column, centered and constrained by window space. Protected and contextually editable wrappers both participate. Fixed table layout and wrapping preserve all cell text; paragraphs and code retain their normal measure. The obsolete Scrollable table accessibility label is now Table.

Verification: the final regression failed against original CSS (8 failures), then passed with the correction. Five focused native tests pass, including complex table editing/undo and narrow-layout checks; 58 renderer tests pass. The table test covers Read and Write, light and dark, 1400/800/360px viewports, enlarged text, eight columns, links, inline code and a short editable table. It asserts actual scrollability, non-whitespace text rectangles, viewport limits and unchanged source. WebKit includes hanging whitespace in editable scrollWidth, so this is not mistaken for clipped text.

The installed regular app was visually inspected with a disposable table document in Read and Write. Screenshots: /private/tmp/folio-tables-wide.png and /private/tmp/folio-tables-write.png. Every column of the eight-column example is visible, long code wraps, and the table extends evenly beyond the heading/paragraph measure. No user document was edited.
