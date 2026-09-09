# STATE

> Machine-owned execution memory. Updated every iteration; committed atomically with the code it describes.
> A fresh engine invocation must be able to resume from this file plus the repository alone.
>
> **This file is read in full at Orient, every iteration, so it must not grow with the run.** Its two
> append-only sections are therefore split into a short index kept here and a full record kept in the
> branch's commits, retrievable with `git show <sha>:<path>` — the same index/archive split ADR-008
> applies to `knowledge/ISSUES.md`. Nothing is discarded; the detail simply stops being re-read every
> iteration. Compacting is part of Persist (ENGINE.md §6.9), not optional housekeeping.

## Current

- **Phase:** bootstrap | executing | done-candidate | escalated
- **Loop Branch:** loop/…
- **Next task:** …
- **DONE-candidate:** no

## Progress

| Task | Status | Evidence |
|---|---|---|
| T-001 | pending / in-progress / complete / blocked | … |

## Assumptions

<!-- Minor PRD/DoD ambiguities resolved by recorded assumption (auditable, reversible). Behavior-defining ambiguity escalates instead. -->
- …

## Recent Iterations

<!-- The last THREE iterations, verbatim, newest first. Older ones move to the index below.
     Three, not one: Recover needs the previous iteration, and POLICIES.md allows three attempts per
     task — so three entries are what it takes to see a retry loop forming rather than one failure. -->

### Iteration N — <timestamp>
- Attempted: …
- Learned: …
- Reconciled: …

## Iteration Index

<!-- One line per iteration older than the three above. The SHA is the checkpoint commit whose
     STATE.md still holds that iteration's full entry:  git show <sha>:.ai/STATE.md -->

| Iteration | Checkpoint | What happened |
|---|---|---|
| 1 | `<sha>` | one line |

## Escalation Index

<!-- One line per consumed Escalation Request, newest first. The full request, the human's decision
     and their rationale live in the checkpoint commit named here, and in that commit's message:
     git show <sha>:.ai/ESCALATION.md
     A pending escalation is not indexed — it is still in .ai/ESCALATION.md, unanswered. -->

| ID | Checkpoint | Question → decision |
|---|---|---|
| D-001 | `<sha>` | one line each side of the arrow |
