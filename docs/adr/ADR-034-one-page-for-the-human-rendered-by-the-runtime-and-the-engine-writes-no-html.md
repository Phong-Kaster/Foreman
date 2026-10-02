# One page for the human, rendered by the Runtime; the engine writes no HTML

By 2026-10-02 a consumer repository could hold three pages for one person to read.
`SUGGESTIONS.html` carried the Decision Queue, the checks awaiting a signature and the Suggestion Box,
and the engine wrote it. `RUN-REPORT.html` carried an Autonomous run's outcome, assumptions and recovery
entries, and the Runtime wrote it. `DOD.html`, built that same day, carried every Definition of Done in
the repository's history, and the Runtime wrote that too.

The engine's page was the one that failed. On the Calendar-Note alarms run its Escalate tab was never
regenerated once, and the human waited about 46 minutes across two decisions nobody knew were queued
(the comment above `Open-EscalationQueue` in `run.ps1`, now removed with it). On a later run sixteen
unsigned criteria vanished from it when a new goal deleted `.harness/run/` (ENGINE.md §11). The Runtime
already had a check for this: on `ESCALATE` it opened the page only if every pending `D-0NN` appeared on
it, and otherwise warned "STALE" and opened the raw Markdown instead. That check existed because the
engine forgets, and the cost of not forgetting was high too: every change to the queue meant reading the
41,298-byte `SUGGESTIONS.template.html` and writing the whole page back.

**Decided by the human, 2026-10-02:** one HTML file to read, instead of several.

**What would change this assessment.** A page so large that rendering it after every iteration costs
measurable wall-clock time, or a section that needs judgment to present - a summary, a ranking - which
the Runtime must not make. Either argues for moving that one section back to the engine, as Markdown it
writes and the Runtime still renders.

## The decision

**`FOREMAN.html` at the repository root, rendered by `run.ps1` after every iteration and on every exit,
in both Run Modes**, with four tabs:

- **Needs you** - every pending Decision Queue entry (in `ESCALATION.md`, not marked answered or
  archived, and with no heading of its own in `DECISIONS.md` - the test the `/foreman` skill already
  used), and the unticked checks under "Awaiting a person" in `ISSUES.md`. The page opens here whenever
  anything is waiting, and the Runtime opens the page on `ESCALATE`.
- **Definition of Done** - the current run's DoD read from disk, then every earlier one rebuilt from git,
  newest first, each criterion keeping its own number under its category heading.
- **This run** - outcome, iterations, the Issues Report, Assumptions, Recovery entries and state. In
  Autonomous mode this tab is the Run Report, warning included; in Collaborative mode the warning is
  hidden and the tab is still there.
- **Suggestions** - `.harness/SUGGESTIONS.md`.

**The engine writes no HTML.** The Suggestion Box moves to `.harness/SUGGESTIONS.md`, a sibling of
`ISSUES.md` that survives the Cleanup Commit, with its own template. ENGINE.md §5 says "No HTML, ever";
§7 loses the paragraph telling the engine to regenerate the page before `ESCALATE`, and the one rule in
it that a real run earned - a check awaiting a signature leads with what is still unlooked-at - moves to
§11 step 4, where those checks are written. ENGINE.md shrinks by 321 bytes and POLICIES.md by 156.

**The stale-page check is deleted**, not kept: a page the Runtime renders from the files themselves has
no way to be missing an entry those files hold. `RUN-REPORT.html` and `DOD.html`, the Runtime's own
excluded files, are removed when the page is rendered, so nobody reads one of them beside the live page.
`SUGGESTIONS.html` is the engine's committed file, not the Runtime's to delete: the Suggestions tab
links it while it exists.

`run.ps1 -Page` renders the page and opens it without starting a run. It takes no lock and leaves the
Run Mode file alone, so it is safe beside a live loop.

## Checked on real data

Rendered from a scratch clone of `Foreman-Proving-Ground` (the Calendar-Note repository, renamed) on
`loop/music-player-v3`: seven Definitions of Done from git, the seven checks that run left under
"Awaiting a person", and its old `SUGGESTIONS.html` linked. Doing it found three defects before any test
did. The section match missed "Awaiting a person" entirely, because the engine's files are CRLF and a
multiline `$` does not match before `\r`. A ticked box would have been counted as still waiting. And
the engine's `*emphasis*` showed its asterisks, which needed an emphasis rule that leaves a code span
such as `Bash(*DebugAndroidTest*)` alone.

## Considered Options

- **Keep the three pages and add an index linking them** - rejected: still three files, and the
  engine's page still goes stale behind the link.
- **Let the Runtime render the Escalate tab itself** - the option ADR-029 rejected, on the ground that
  turning Markdown into HTML is "far past what an intentionally dumb runtime should contain" (ADR-002).
  Reversed here because that premise was overtaken a month later: ADR-027 put exactly that converter into
  `run.ps1` for the Run Report, and it is a line-by-line subset of Markdown with no judgment in it. The
  dumb-runtime principle is about decisions - what to do next, whether work is done - not about
  formatting. **This was the closest call:** the converter grows with this ADR (emphasis, task boxes),
  and a converter that keeps growing is how a dumb runtime stops being one.
- **Render only on demand, with `-Page`** - rejected: the person a run stops for at `ESCALATE` should
  not have to know a command to see why.
- **Keep the Suggestion Box as HTML the engine writes, and embed it** - rejected: it keeps the one page
  that has already gone stale, and the 41 KB template the engine pays to read.

## Consequences

- One file to open, and it opens itself at the gate. Everything on it is rebuilt from Markdown the
  engine already keeps, so a reader can always trace a line on the page to a file.
- The page is excluded from git, so it is not visible to someone browsing the repository on GitHub;
  `SUGGESTIONS.html` was committed and was. `.harness/SUGGESTIONS.md` is committed and renders there as
  Markdown, which covers the Suggestion Box; the rest was always per-run state.
- Supersedes in part ADR-026 (the Escalate tab as an engine-written mirror) and ADR-027 (the Run Report
  as its own file, Autonomous-only), and reverses ADR-029's rejected option.
- **Not solved:** entries already in a repository's `SUGGESTIONS.html` are not migrated into
  `SUGGESTIONS.md`; they stay readable through the link until a person moves them.
- **Not solved:** the Needs you tab shows a decision only if `ESCALATION.md` gives it a `D-0NN`
  heading. An entry the engine writes in another shape stays in the file and off the page.
- **Open:** the page is rendered between iterations, never during one. That is enough for the gate,
  which is only ever reached at an iteration's end, and not enough for anyone hoping to watch a long
  iteration from the page.
