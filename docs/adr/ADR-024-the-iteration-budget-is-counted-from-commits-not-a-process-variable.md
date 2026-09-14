# The iteration budget is counted from commits already on the branch, not a process-local variable

ADR-012 gives the Runtime exactly one bound against an engine reporting `CONTINUE` forever on an
impossible goal: `MaxIterations`, default 50, "per run." ADR-021 closed a neighbouring defect and
named this one on its way out without fixing it:

> **Not solved:** nothing bounds what a run may spend in wall-clock or money, and the iteration
> budget still resets on every process restart — so a run that escalates or crashes repeatedly has
> no effective ceiling.

The mechanism was a `for`-loop variable:

```powershell
for ($iteration = 1; $iteration -le $MaxIterations; $iteration++) { ... }
```

`$iteration` lives in the memory of one PowerShell process. Four of `run.ps1`'s five terminal
outcomes — `ESCALATE` (exit 3), the Crash-limit (exit 2), `FAILED` (exit 4), and a quota ceiling
(exit 6) — end that process on purpose, expecting the human or the Skill to invoke `run.ps1` again.
Every one of those restarts sets `$iteration` back to 1.

**The field measurement** (Phong-Kaster/Calendar-Note, `loop/calendar-note-app`, 2026-09-10 →
09-11): the run restarted six times — a killed session, a quota exhaustion, and four operator
interruptions — each handed a fresh budget of 50 for free. A run that escalates five times over its
life receives 250 iterations against a document that describes the number as a safety ceiling for
the whole run. `ESCALATE` is the ordinary, designed response to an under-specified PRD (`ENGINE.md`
§5: "the DoD approval is the only blocking gate in a run"), so the two conditions most likely to
recur in a real run — a PRD needing clarification, and a long unattended run meeting a quota window
— are exactly the two that bypass the bound meant to catch a stuck engine.

## The fix

`ENGINE.md` §6 already requires every non-crashed Iteration to "end at exactly one Stable
Checkpoint... persisted as one atomic git commit." That invariant means the commits already on the
Loop Branch **are** the count of iterations already spent, and unlike a loop variable, that count
survives a process exiting, because git does.

`run.ps1` now resolves the branch's base (`origin/HEAD`, falling back to a local `main` or `master`)
and seeds the loop counter from `git rev-list --count <base>..HEAD` instead of from 1:

```powershell
for ($iteration = $priorIterations + 1; $iteration -le $MaxIterations; $iteration++) { ... }
```

On the first invocation of a run, HEAD has not diverged from the base yet, so `$priorIterations` is
0 and the loop starts at 1 — identical to today. On every subsequent invocation, HEAD is the Loop
Branch tip, and every commit on it is one Iteration a *prior process* already completed. The 50-item
budget now spans the run's entire lifetime, restarts included, with no new file, no new capability,
and no change to behavior within one continuous process.

If neither `origin/HEAD` nor a local `main`/`master` can be resolved — a repository with no remote
and an unconventionally named default branch — the count silently falls back to 0. This is never
worse than the defect being fixed; it just leaves that one configuration exactly as unbounded as it
was before this change.

## Considered Options

- **A file under `.harness/run/` recording the count or the base SHA** — rejected. It is a sixth
  artifact with a sixth lifecycle, and it would need to be written exactly once, at bootstrap,
  before `.harness/run/` itself is guaranteed to exist — the same directory-creation-order problem
  the Runtime already avoids elsewhere. The information already exists, durably, as commits; a file
  restating it can only drift from what git actually holds.
- **A wall-clock or dollar ceiling instead of an iteration count** — rejected as a *replacement*: it
  answers a different question (ADR-012 already owns cost and time separately) and would not, by
  itself, stop a stuck engine that is cheap and fast. It remains a candidate as an *additional*
  bound; this ADR only fixes the counting of the one that exists.
- **Hardcode the base branch name to `main`** — this was the field report's own suggested fix text,
  and was the closest call. Rejected because `ENGINE.md` and `POLICIES.md` never name a specific
  branch — they say "the default branch," consistently, because Foreman installs into consumer
  repositories that are free to call it `master` or anything else. `origin/HEAD` is what a human
  would check first and is exactly the fact git already tracks for this; `main`/`master` is the
  fallback for the common case of a fresh local repository with no remote yet, which is what every
  Pester test in this suite is.
- **Reset the counter explicitly at a detected Cleanup Commit** — rejected as unnecessary: nothing
  needs resetting. The count is `git rev-list --count <base>..HEAD`, and once a Loop Branch is
  merged, `HEAD` on the next branch is cut from the new `main`, so a fresh branch's count is 0
  without any code asking it to be. Explicit reset logic would exist to handle a case that git's own
  topology already handles.

## Consequences

- The per-iteration log line (`=== Iteration $iteration / $MaxIterations ===`) now reports the
  correct cumulative count after a restart, which was itself part of finding #08 in the field
  report — an operator watching the log across a restart previously saw the count lie.
- The budget's unit is now "Stable Checkpoints," not "process invocations." A quota wait or a
  rejected invocation already does not consume an iteration (ADR-021 decrements `$iteration` back
  before `continue`), so this is consistent with the existing accounting, not a new category.
- **This assumes one Loop Branch per PRD, merged before the next one starts** — already the
  documented lifecycle (`ENGINE.md` §5 creates the branch once, at bootstrap; `POLICIES.md` never
  provides for reusing an unmerged branch across two PRDs). If that assumption is violated — a
  second PRD run on a branch before the first is merged — its budget starts elevated by the first
  PRD's commit count. This is a misuse of the documented lifecycle, not a new failure mode this
  change introduces, but it is worth stating because nothing currently detects the violation.
- **Not solved:** a crashed Iteration produces no commit and therefore is not counted here at all —
  it is bounded separately, by `MaxConsecutiveCrashes`, and the two bounds still do not share a
  ledger. A run alternating one crash and one genuine Iteration indefinitely would exhaust neither
  bound on its own. Closing that gap is a separate change, in the same spirit as this one: derive it
  from something durable rather than a variable that resets.
- **Not solved:** wall-clock and cost still have no ceiling of their own (ADR-012's quota bound
  guards usage-window headroom, not total spend). `git rev-list --count` says nothing about how
  expensive each counted Iteration was.
