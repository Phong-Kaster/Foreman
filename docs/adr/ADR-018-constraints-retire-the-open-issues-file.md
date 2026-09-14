# Constraints retire the Open Issues file, but not the rule that earned it

ADR-020 gave known defects a durable home: `knowledge/ISSUES.md`, engine-maintained, read at Orient every iteration, holding what is **still wrong** so a later iteration avoids reproducing it. It was written against the `.loop` runtime.

The `.harness` runtime that replaced it (ADR-014) arrived with a different mechanism for the same problem — **Constraints** (ADR-016) — and with a file of its own already called `.harness/ISSUES.md`, which is not the same artifact at all:

| | `.harness/ISSUES.md` (ADR-016 era) | `knowledge/ISSUES.md` (ADR-020) |
|---|---|---|
| What it is | A **report**, regenerated every Iteration | **Knowledge**, accumulated across runs |
| Holds | Abandoned tasks, queued decisions, unsigned `human` criteria | Defects that are still wrong |
| Read by | A **person** returning to a stopped run | The **engine**, at Orient |
| Answers | "what is stuck?" | "what must I not copy?" |

Two artifacts, one filename. Only the first exists in the runtime today; ADR-020's doctrine was left behind by the merge and has never been reinstated.

## Constraints are the stronger mechanism, and ADR-020 said so first

ADR-020 closed by naming its own ceiling:

> **Also not solved:** the engine still cannot be made to *act* on an entry. `ISSUES.md` informs the work; it does not schedule it.

A Constraint does not wait to be read. It is carried **verbatim into every Worker Brief, never filtered**, and the Fresh-Context Review checks the diff against each one, where a violation is a blocking finding rather than an opinion. That is precisely the gap ADR-020 could not close, closed.

Everything else ADR-020 asked for, ADR-016 already requires independently: entries earn their place by having cost something, they cite evidence so they can be checked and retired, they are deleted when they stop being true, and they are recorded in the same checkpoint that discovered them.

**Decision: `knowledge/ISSUES.md` is retired.** ADR-020 is superseded. No file is reinstated, the name `.harness/ISSUES.md` stays with the report, and known defects live in `PROJECT.md` as Constraints.

## What retiring it would have lost, and does not

The Constraint/Reference split sorts by one question — *if a Worker ignored this, would the result be wrong?* That question returns the wrong answer for a known defect, and returns it confidently.

Take the fact that produced ADR-020 in the first place: `CoreLayout.kt` paints a hardcoded black background, and no screen sources its colours from the theme. Ignore it, and a Worker takes its colours from the theme — which is **better**. The literal test therefore files it as a **Reference**, and a Reference is a convention to conform to. The next Worker conforms, and the defect ships again.

That is not a hypothesis. It is the original ADR-020 failure, reachable through the new taxonomy by the same route as the old one: the binary has no slot for *"this is how the code is, and it is wrong."*

A Constraint **can** carry it — "never take a colour from `CoreLayout`'s pattern; source every colour from the theme" — but only if the engine writes the **instruction** rather than the **observation**. Writing the observation is the natural reflex on discovering a fact about a codebase, and it is the one that reproduces the bug.

So `POLICIES.md` § Constraints vs Reference gains the rule, and only the rule: a defect known and unfixed is always a Constraint, phrased as what a Worker should do about it. The test to apply is not *"would ignoring this be wrong"* but **"what should a Worker do about it?"** — if the honest answer is *avoid it* rather than *follow it*, it is a Constraint whatever the first question says.

## Considered Options

- **Reinstate `knowledge/ISSUES.md` under a new name** (`DEFECTS.md`) — rejected. It reintroduces a second mechanism for one job, and the weaker one: entries wait to be read where Constraints are pushed into the Brief. Two places to look for "what is wrong here" is how one of them goes stale.
- **Retire ADR-020 wholesale, rule included** — rejected, and this is the option that looks cleanest on a file listing. ADR-016's sorting question demonstrably misfiles a known defect, so retiring the rule alongside the artifact would reopen the exact failure ADR-020 was written for. The artifact was replaceable; the rule was the finding.
- **Keep both, with `ISSUES.md` narrowed to defects the engine will not fix this run** — rejected: that is a distinction about *scheduling*, not about *knowledge*, and it is already carried by the task file that was abandoned and by the Issues Report a human reads.
- **Add a third sort alongside Constraint and Reference** — rejected: the same reasoning that kept Verification Class at two arms (ADR-017). A known defect is a Constraint once phrased correctly; the problem was never that the category was missing, only that the sorting question pointed away from it.

## Consequences

- One mechanism for "what must not be copied here", reaching the Worker rather than waiting for it.
- `.harness/ISSUES.md` keeps its name unambiguously, and the merge collision closes without renaming anything.
- The sorting question in `POLICIES.md` now has an explicit exception, which is a cost: the section is read by every Worker Brief assembly. It is earned — a shipped defect, twice, by the same mechanism — but it is prose paid for per-iteration and should stay as tight as it is.
- ADR-020's other contribution survives independently and is untouched by this: `Bash(git show*)` in the baseline ledger, without which branch history is an archive the engine cannot read.
- **Not solved:** nothing verifies a Constraint is still true, which was ADR-020's own unsolved consequence inherited unchanged. A defect fixed by a human between runs leaves a Constraint that misleads until an iteration happens to notice. ADR-016 says delete it when it stops being true; nothing checks.
- **Not solved:** a Constraint is still repository-local. A defect pattern worth avoiding in every Android repository has no home above `PROJECT.md`, which is the `CANDIDATES.md` gap ADR-019 deferred and this run met.

**Decided by the human, 2026-09-11:** retire the artifact, keep the rule. The reasoning offered was that the project is built around durable knowledge — each failure becoming knowledge the harness carries forward — and that Constraints serve that better than a file the engine must remember to read.
