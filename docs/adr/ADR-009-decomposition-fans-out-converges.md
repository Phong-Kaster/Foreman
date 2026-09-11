# Decomposition fans out for analysis and converges to a single author

When the PRD is large, one context decomposing it alone produces shallow tasks and misses repository conventions. Bootstrap therefore dispatches parallel analysis agents:

- one surveying the codebase's conventions and structure,
- one proposing candidate DoD criteria,
- one proposing a candidate task decomposition,
- one **independently critiquing** that decomposition: missing tasks, wrong dependencies, tasks that are not shaped as observable behavior per `POLICIES.md` § Task Decomposition,
- one **conflict analysis** mapping each candidate task to the files it would touch, and therefore which task sets are safe to place in the same Phase.

The parent alone then writes `DoD.md`, `PLAN.md`, and the task files. One plan, one task graph, one author, always.

## Considered Options

- **A single agent decomposes alone** — retained for small PRDs, where fan-out is pure overhead. Rejected as the only mode: it is the case that produced the field finding "plan granularity must scale with PRD size".
- **Several agents each decompose a slice, outputs concatenated** — rejected, and this is the important rejection. No slice-owner sees the whole, so none can determine the dependency graph *between* their tasks. That graph is precisely what both the Decision Queue (ADR-007) and Phase selection (ADR-008) depend on, so concatenation produces a task set whose safety nobody has established.
- **Human approves the plan** — already rejected by ADR-001 and unchanged here: the human owns what *done* means, the engine owns how to get there.

## Consequences

- The conflict-analysis agent produces exactly the input Phase selection requires, so Phase grouping is derived from analysis rather than guessed at during execution.
- The critique agent is a checker role, so ADR-005's three-minds principle now covers planning as well as code: the context that proposed a decomposition is the least likely to notice what it omitted.
- Fan-out costs one subagent call per analysis role, paid once at bootstrap. Cheap against a multi-hour run; wasteful on a two-task PRD, hence the size threshold.
- The five roles are read-only analysts. They propose; they never write `.harness/run/`. The single-author rule is what keeps the task graph coherent.
