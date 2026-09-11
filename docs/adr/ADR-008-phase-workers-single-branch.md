# A Phase is the unit of parallel work; Workers run in place on one branch

A **Phase** is a set of tasks with no unmet dependencies and no overlapping file scope. One Iteration executes one Phase.

The parent (the Iteration's own context) assigns each task a **Declared File Scope** and dispatches one **Worker** per task. Workers edit files in the single shared working directory and hold **no git, build, or test capability** — enforced by their agent definition, not by instruction. The parent alone then builds once, tests once, takes the Fresh-Context Review on the combined diff, writes state once, and commits **one atomic checkpoint on the single Loop Branch**.

One writer, one committer, one checkpoint per Iteration. ADR-003 is therefore untouched.

Per-Worker git worktrees were the obvious alternative and are technically excluded: **git refuses to check out one branch in two worktrees.** "One branch" and "a worktree per Worker" are mutually exclusive, so choosing one branch removes worktrees from the design entirely — along with their merge step, their merge-conflict class, and the `git worktree` capability they would require.

## Considered Options

- **A worktree and branch per Worker, merged by the parent** — rejected: git forbids two worktrees on one branch, so this forces multiple branches plus a merge step. It buys filesystem isolation at the cost of a new capability, a new failure class, and the one-branch property.
- **Peer engines, each a full Iteration, writing a shared state file** — rejected: concurrent `git commit` in one working directory corrupts the index, and concurrent appends corrupt the state file. This is the accident the run lock exists to prevent.
- **Workers build and test their own tasks** — rejected: the build output directory is shared, so concurrent builds collide. Verification converges on the parent instead, and failure attribution is solved by the Declared File Scope (see Consequences).
- **Sequential tasks within a Phase** — not rejected, retained as the safe fallback. The token saving comes from *grouping tasks into Phases* (fewer Iterations, fewer orientation reads), not from parallelism; parallelism only buys wall-clock. Grouping sequentially therefore delivers the full token saving with zero collision risk, and parallelism can be enabled as a separate speed decision.

## Consequences

- The filesystem no longer hides a collision, so scope must be **verified, not merely planned**. Each Worker reports the files it wrote; the parent checks pairwise disjointness, containment within the Declared File Scope, and that the union matches `git status`. A violation means the plan was wrong to call the tasks independent: revert, re-split, log a Tier-1 amendment.
- **Shared integration points belong to the parent, never a Worker.** Two independent screens still both touch the navigation table, route registry, or manifest — the classic hidden conflict. The Worker builds its own screen's files; the parent does the shared wiring after merging. The conflict-analysis agent (ADR-009) exists to find these.
- **The Declared File Scope does double duty.** Beyond collision prevention, it attributes build failures: a compiler error names a file, the file maps to exactly one Worker, and the parent re-dispatches that Worker with the error. Each re-dispatch counts as an attempt under the three-attempt rule, so repeated failure abandons the task per ADR-007.
- `STATE.md`'s existing `Phase` field is renamed **`Stage`** (bootstrap / executing / done-candidate / escalated). `Phase` now means the task group. Both meanings cannot share the word.
- The loop occupies the working directory for the whole run; a human cannot work in that repository concurrently. Accepted deliberately — the target use case is unattended overnight execution.
- The checkpoint commit message changes shape: a Phase-level summary as the first line, written for a human skimming `git log`, and a body listing what each Worker did with its build/test evidence.
- **A Phase holds at most three tasks** (a tunable recorded in `POLICIES.md`, not a truth). The parent's context accumulates one Brief out and one manifest back per Worker on top of the combined diff, build output, and review, so an unbounded Phase defeats the bounded-context goal the design exists for. The number is to be measured and adjusted.
- The ceiling on concurrent Workers is **observable, so it must be discovered rather than assumed**: `result` events carry `subagent_stats.refused.concurrency_limit`. A Phase size that silently exceeds the platform's limit would serialize anyway while appearing parallel.
- **Concurrency spends quota faster in wall-clock terms.** Three Workers consume the account's usage window roughly three times as fast, though total tokens are unchanged. When quota is the binding constraint rather than time — which is the case for a loop under minimal supervision (ADR-012) — sequential Workers spread the same window across more work. Recommended rollout is therefore sequential first, concurrency enabled only after measurement.
- Retires "parallel task execution" from the deferred list in architecture.md §12; the stated trigger (sequential throughput becoming the bottleneck) is met.
