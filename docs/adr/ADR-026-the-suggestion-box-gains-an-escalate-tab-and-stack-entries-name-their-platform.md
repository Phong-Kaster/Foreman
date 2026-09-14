# The Suggestion Box gains an Escalate tab, and every stack-tier entry names its platform

Commit `92baf7f` gave the engine a write path for a lesson that is true beyond the repository it was
found in: `SUGGESTIONS.html`, regenerated at the repository root, read-only, never acted on by the
engine itself (ADR-019). It solved the write problem. It did not solve two others, both found by
using it rather than by reading it:

**There was still nowhere for a blocking question to be read comfortably.** `.harness/run/ESCALATION.md`
carries the Decision Queue — id, question, context, options, recommendation, blocked tasks — but only
as plain Markdown a human opens and parses by eye. The Suggestion Box already existed as the
one HTML surface Foreman ships to a human at the repository root; splitting "the thing that blocks
you" and "the thing you read at your leisure" across a rendered page and a raw log file was an
accident of the order the two were built in, not a decision.

**A `stack`-tier entry did not say which stack.** The only two entries Calendar-Note's audit found
tagged `pack` were both Android (`android.jar` stub, `updateDebugScreenshotTest` orphaning
reference images), so the gap was invisible with one platform in play. It stops being invisible the
moment backend or frontend work starts landing suggestions of its own: an undifferentiated `pack`
tag mixes lessons a human curating an Android pack has no way to use with ones they do.

## Decision

`SUGGESTIONS.html` gets two tabs, **Escalate** and **Suggestions**, sharing one page, one language
switch, and one visual language. Escalate is a read-only mirror of `ESCALATION.md`, regenerated
whenever that file changes; a banner says plainly that the answer belongs in `DECISIONS.md`, never
here. The tab that opens by default is whichever one actually holds a card — an empty Escalate tab
opening first would make the human click past nothing on every run that has none queued.

A `stack`-tier suggestion must name its platform, appended to the tag after " · " — `pack · android`,
later `pack · backend`, `pack · frontend`, `pack · devops` — matching the `skills/knowledge/<platform>/`
folder it would land in. `skills/knowledge/` is reorganised the same way: one subfolder per platform,
so `skills/knowledge/android-compose-visual-testing/` becomes `skills/knowledge/android/compose-visual-testing/`.

Every card in both tabs is a native `<details>`/`<summary>` element, closed by default. The tab
badge counts (`<span class="n">`) are computed by the page's own script from the cards actually
present, never hand-authored — a hand-maintained count was tried first and was wrong the same day it
was written: three Escalate cards on the page, the badge still reading two, because "pending only"
and "every card" are both plausible readings of the label and the one chosen was not the one
displayed.

## Considered Options

- **A separate `ESCALATION.html` file, cross-linked from `SUGGESTIONS.html`.** Rejected: it keeps the
  mechanisms that generate each file simplest, but it recreates exactly the split the human was
  pointing at — two places to open instead of one — for two things that are both "read this, then go
  answer/act somewhere else," differing only in urgency. Chose the shared-tab option instead.
- **Grouping stack entries into per-platform sections (Android / Backend / Frontend / DevOps
  headings) instead of a sub-tag.** Rejected *for now*: with exactly one platform in real use, three
  of four headings would sit permanently empty, which is the same mistake ADR-019 warns against —
  building structure for a volume of content that does not exist yet. A sub-tag costs one token of
  text and needs no empty scaffolding; revisit grouping if a platform's entries start arriving in
  enough volume that scanning a flat list stops working.
- **Flat `skills/knowledge/<platform>-<topic>/` naming instead of a subfolder per platform.**
  Considered and rejected in favour of the subfolder, on the strength of the same principle Git
  commit scopes already apply in this repository (`.claude/git-commit-message.md`): a scope should be
  something a reader would go looking for, and a browsable folder is easier to go looking in than a
  naming convention nothing enforces.
- **Leaving the badge counts hand-maintained, with a comment instructing the author to update them.**
  This was the original design and it failed within the same session it was written in — proof that
  "a rule enforced by a script is a rule, a rule living only in a comment is a wish" (ADR-002) applies
  exactly as much to a demo file as to doctrine.

## Consequences

- `ENGINE.md` §5 and §7 now describe `SUGGESTIONS.html` as carrying two tabs, and instruct
  regenerating the Escalate tab in the same step that appends to `ESCALATION.md`.
- `POLICIES.md`'s Suggestion Box criteria now require a platform name on every `stack`-tier entry.
- `skills/knowledge/android/compose-visual-testing/` is the only pack that exists today; the
  subfolder convention is proven by exactly one occupant.
- **Not solved:** there is still no index of installed stack packs (a `skills/knowledge/README.md`
  listing what exists per platform). With one pack this is not yet a real cost; it becomes one the
  day a human has to remember whether a backend pack already exists before writing a new one.
- **Not solved:** nothing verifies that `SUGGESTIONS.html`'s Escalate tab was actually regenerated
  when `ESCALATION.md` changed — the same class of gap ADR-019 left open for the Suggestion Box
  itself ("an unread suggestion box is the same as no suggestion box"), now doubled onto a
  second file the engine must remember to keep in sync by discipline alone.
