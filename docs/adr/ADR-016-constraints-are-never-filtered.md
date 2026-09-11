# Knowledge splits into Constraints and Reference; Constraints reach every Worker verbatim

`knowledge/` is the reason this architecture is worth more than a bare goal-loop. Everything else —
the critique role, the fresh Verifier, the evidence rule — improves a single run. `knowledge/` is the
only mechanism by which run *n+1* starts smarter than run *n*. A knowledge layer that does not reach
the context doing the work is worse than none, because the run paid to learn the lesson and then
discarded it.

It did not reach the work. Measured, one commit apart:

| Commit | What happened |
|---|---|
| `49c3335` (Phase 1) | Recorded in `knowledge/PROJECT.md`: `onBackground`/`onSurface` are not overridden in `Theme.kt`, `CoreLayout.kt:38` paints the background `Color.Black` unconditionally, so sourcing from the colour scheme would be **"near-invisible"** |
| `cbce81f` (Phase 2) | A Worker created `CalendarNoteList.kt` using `colorScheme.onSurface` for its text and both icon tints — invisible against that same black background |

The engine inferred the trap correctly, wrote it down in the right place, and then a Worker in the
very next Phase did the forbidden thing. Nothing about this was an intelligence failure. The Worker
was never told.

The cause is one word in the Worker Brief contract: it carried "the conventions from `knowledge/` it
**needs**". Deciding what a Worker needs is a judgement, judgement filters, and this filter dropped
the one entry that mattered. The Worker then read DoD criterion 30 — "never hardcode colours" — and
complied with it literally, which is exactly what the discarded warning predicted would fail.

There is an irony worth recording: ADR-010 shrank the Worker Brief to "status, not story" to keep
per-iteration cost flat. That optimisation is what discarded the hard-won lesson. It was written to
save tokens and it cost a shipped defect.

Therefore `knowledge/` splits in two:

- **Constraints** — traps. "Never X here, because Y." Violating one produces a defect. They are
  carried **verbatim into every Worker Brief**, never filtered, never summarised, never judged
  relevant or irrelevant by the dispatching Iteration.
- **Reference** — everything else: build commands, layout, naming, conventions that help a Worker
  move faster but whose violation is untidy rather than wrong. Still filtered to what the task needs.

The test for which is which: *if a Worker ignored this, would the result be wrong?* Yes means
Constraint.

The Fresh-Context Review checks the combined diff against the Constraints list explicitly. A
violation is a **blocking** finding, not an opinion — it is the one review category where the
reviewer is comparing against a written rule rather than exercising taste.

## Considered Options

- **Put all of `knowledge/` in every Brief** — rejected, though tempting because the file is small
  today (78 lines in the trial). It grows without bound as a repository accumulates facts, and
  ADR-010's flat-cost property is worth keeping. More importantly it flattens the signal: a Worker
  reading forty lines of build trivia to find one trap is close to not being told.
- **Have the Iteration filter more carefully** — rejected. This *was* the design, and it failed. The
  fix for a judgement that dropped something cannot be the same judgement applied harder.
- **Let the Reviewer catch it instead of preventing it** — rejected as the sole mechanism, and
  adopted as the second one. Review after the fact costs a re-dispatch and an attempt; the Brief
  costs a few lines. Both, in that order.
- **Encode traps as lint rules or tests instead** — the strictly better answer *where it is
  possible*, and it should be preferred whenever a Constraint can be mechanised. It was not possible
  here: no lint rule expresses "this colour is invisible against the background this app happens to
  paint". Constraints are for the traps that resist mechanisation.

## Consequences

- Constraints must stay few and terse, or the mechanism destroys itself: if everything is a
  Constraint, the Brief is once again a wall of text with the important line buried. A Constraint
  earns its place by having cost something — a defect, a failed attempt, a review finding.
- Each Constraint cites its evidence (`file:line`), so it can be checked and, when the underlying
  code changes, retired. `knowledge/` remains a cache: the codebase wins on conflict, and a
  Constraint that no longer holds must be deleted rather than left to mislead.
- Reconcile (§8) must promote a discovered trap to a Constraint **in the same checkpoint that
  discovered it**. The trial's failure window was one commit wide; a delay of one Phase is enough to
  ship the defect.
- The Reviewer's prompt gains a concrete checklist, which is a strict improvement over open-ended
  judgement for this category.
- This is the mechanism by which future runs inherit experience. A Constraint written during one
  goal is still binding on every Worker in every later goal in that repository — which is the whole
  claim `knowledge/` makes, now actually delivered to the place the work happens.
