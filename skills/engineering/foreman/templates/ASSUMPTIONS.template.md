# ASSUMPTIONS

> Autonomous mode only (ENGINE.md §14.1, ADR-027). Every decision the engine made alone, where a
> Collaborative run would have stopped to ask. The Runtime renders this file into `RUN-REPORT.html` at
> the end of the run, so each entry must make sense to someone who has read nothing else.
>
> To overturn one: answer its id in `.harness/run/DECISIONS.md` and re-run. A human answer always
> outranks an assumption — the engine reverts what depended on it. Or run the revert command below
> yourself, on the Loop Branch, after the run has stopped.

---

## A-001 - <short title>

- **Tier:** 2 (plan/architecture) | 3 (intent) | Missing information
- **Iteration:** N
- **First dependent checkpoint:** <commit SHA — filled in by the Iteration after N>
- **Revert:** `git revert <sha>`
- **Assumed DoD criteria:** <Tier 3 only: the criterion numbers this reading affects; they can never make the run DONE>

### Question

<!-- What a Collaborative run would have asked the human. -->

### Options Considered

1. ... - consequences: ...
2. ... - consequences: ...

### Taken, and why

<!-- The option applied and the reasoning. For Tier 3: why this is the reading closest to PRD.md's literal text. -->
