# Known defects live in `knowledge/ISSUES.md`, addressed by commit SHA, and the engine may read history

> **SUPERSEDED by [ADR-018](./ADR-018-constraints-retire-the-open-issues-file.md), 2026-09-11.**
> `knowledge/ISSUES.md` is retired. Constraints (ADR-016) carry known defects into every Worker
> Brief instead of waiting to be read at Orient — which closes the ceiling this ADR named in its own
> last line. The **rule** survives and moved to `POLICIES.md` § Constraints vs Reference: a known
> defect is always a Constraint, phrased as an instruction, never a Reference describing how the
> code is. `Bash(git show*)` in the baseline ledger, also from this ADR, is unaffected and stands.

A run reported a verified `DONE` while leaving a defect its own reviewer had found. Tracing why produced three separate faults, none of which was a reasoning failure.

The evidence is a real consumer run (Phong-Kaster/Calendar-Note, `loop/todo-calendar-screens`). Its Fresh-Context Review found hardcoded colours on the new screens, and the engine did everything the architecture asks: it traced the cause to a pre-existing hardcoded background in a core layout file, reasoned that fixing it literally would risk a contrast regression unless out-of-scope screens changed too, classified it Tier 2, and escalated. The human answered *keep the pattern, reword the criterion*. Then the engine recorded what it had learned in `knowledge/PROJECT.md`:

> `CoreLayout.kt`'s background is hardcoded black regardless of `darkTheme`, and no screen (old or new) sources its own text/icon colors from `MaterialTheme.colorScheme` — a pre-existing, app-wide pattern, not a regression introduced by this run.

That entry is durable, correct, and read at Orient every iteration. It is also the fault. `PROJECT.md` is defined as a cache of operational truth — *how this repository is* — so an entry there reads as the local convention. A later iteration did exactly what the file told it to: it conformed, and hardcoded the colours again. **Recording a defect as a fact does not merely fail to help; it causes the defect to be reproduced on purpose.**

The second fault: the entry ended "see D-002 in …", pointing into the run directory the Cleanup Commit deletes. The reference survived; the referent did not. Nothing was actually lost — `.ai/` is removed from the branch *tip*, and its full history stays in the branch's commits (ADR-003) — but the address had become unresolvable.

The third fault made the second unrecoverable: the baseline Capability Ledger granted `git status/diff/log/add/commit/checkout/branch` and **not `git show`**. Reading a file's contents at a commit is exactly what `git show <sha>:<path>` does and what `git log -p` cannot — it yields diffs, not contents. So the archive existed, the engine knew a pointer into it, and the engine had no command capable of following the pointer.

Three changes, all inside existing lifecycles:

1. **`knowledge/ISSUES.md`** — engine-maintained, human-editable, same lifecycle as `PROJECT.md`, opposite semantics: entries are patterns to **avoid**, not conventions to conform to. Read at **Orient**, every iteration, so a known defect reaches the engine before it writes code rather than after. Entries are **deleted** when resolved, never marked done — the file is worth reading only while all of it is still true.
2. **Addresses are commit SHAs, not paths.** Every entry must be actionable on its own and cite the SHA holding the full record. The Cleanup Commit message must now also carry every escalation with the decision that answered it, and anything still open — removing `.ai/` destroys the tip's only copy, so the message is what makes `git log` alone sufficient.
3. **`Bash(git show*)` joins the baseline ledger.** Read-only, non-destructive, and in the same risk class as the `git log`/`git diff` grants already there; its absence looks like an oversight rather than a decision. History the engine cannot read is not an archive.

## Considered Options

- **Restore a top-level `ISSUES.md` beside `.loop/`, as an earlier iteration of this runtime had** — rejected: it adds a fifth artifact with a fifth lifecycle to solve a problem `knowledge/` already solves. That earlier design kept the file outside the deleted directory, which is the right instinct, but `knowledge/` is *already* outside it and already in the orientation path.
- **Keep everything in `PROJECT.md` and add a "known issues" heading inside it** — rejected: the failure is semantic, not organisational. The engine is told to conform to that file; a heading does not change what conforming means, and the surrounding entries are genuinely conventions it should follow.
- **Put open findings only in the Cleanup Commit message** — rejected as the primary home: commit messages are immutable, so a resolved issue would stay listed forever and the list would decay into noise. Kept as the archive half, where immutability is the point.
- **Rely on the engine querying branch history at Orient** — rejected as the primary mechanism: a history scan every iteration is expensive and, worse, optional. "Proactive" means the knowledge is in the reading the engine already does, not in a search it must think to perform. History is the archive the index points into, once `git show` makes it reachable.
- **Task files for out-of-scope defects** — rejected: `.ai/TASKS/` is per-run and disposable, and an out-of-scope defect is by definition not this run's work. It would be deleted with the rest of `.ai/`.

## Consequences

- Three files in `knowledge/`, and the distinction between them is load-bearing rather than tidy: conform to `PROJECT.md`, avoid `ISSUES.md`, implement `DOMAIN.md` exactly. Reconcile gains a matching classification — *known defect left unfixed* — which is the only one that survives a run without becoming a task.
- The engine can now read any prior run's execution state, since every `.ai/` state remains in the branch's commits and `git show` is granted. The audit trail stops being write-only.
- `ISSUES.md` must be pruned to stay useful. A resolved entry left behind teaches the next reader to distrust the rest, so deletion on resolution is a rule, not housekeeping. This is the removal half of the ratchet (ADR-019), which had a criterion but no process.
- **Not solved here:** nothing verifies that an `ISSUES.md` entry is still true. A defect fixed by a human between runs leaves a stale entry until an iteration happens to notice. The same is true of `PROJECT.md` today, where the codebase-wins rule at least implies correction; `ISSUES.md` has no equivalent forcing function.
- **Also not solved:** the engine still cannot be made to *act* on an entry. `ISSUES.md` informs the work; it does not schedule it. Turning an entry into work stays a human act — a new PRD, or a decision at an escalation.
