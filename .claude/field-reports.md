# Field Reports (HTML)

Human-facing HTML reports Foreman generates - `foreman-field-report.html` and any successor - follow
these. They are operator preferences, not Ratchet lessons: they govern how a report is presented, not
what the engine may do.

- **Language switching is a dropdown (`<select>`), never a two-button toggle.**
  Style the control to the page's own tokens: mono 11px, uppercase, `--rule`
  border, CSS-drawn chevron so it follows the theme rather than the OS palette,
  and explicit `background`/`color` on `option` so the open list stays readable
  in dark mode. Keep the choice in `localStorage`; English is the at-rest default.

- **The topbar is sticky.** Keep it a direct child of `<body>` — outside `.wrap`
  and outside `header.mast` — so its containing block is the whole document and
  it goes on sticking after the masthead scrolls away. A sticky bar nested in the
  masthead scrolls off with its parent, which is the bug, not the fix. Full-bleed
  opaque `--paper` background with a `--rule` hairline; inner row matches the
  `.wrap` max-width and side padding so it lines up with the text column.
