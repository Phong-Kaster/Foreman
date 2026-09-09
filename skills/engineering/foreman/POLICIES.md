# POLICIES

> Generic engineering policy shipped with Foreman. Identical in every consumer repository — project-specific facts belong in `.harness/knowledge/`, never here.

---

## Retry and Abandonment Policy

- Retry a failed approach only when the probability of success has increased: new information, a different strategy, a corrected assumption. Never retry identical work.
- Maximum 3 attempts per task across all iterations (attempts are counted in the task file).
- **The third failure abandons the task.** Mark it abandoned, mark every task that transitively depends on it unreachable, and continue with unrelated work. This is what lets the loop keep progressing without a human present — but a run containing an abandoned task can never report `DONE`.
- **Every failed attempt records its own evidence, at the moment it fails**: the command run and the tail of its error output, written into the task file. Successful work carries its evidence in the checkpoint commit; failed work is reverted and enters no commit, so this is the only place its detail survives. Cap the captured output (about 40 lines) so the Issues Report stays readable.
- A build/test failure caused by a fixable defect in new code is a fix, not a retry — fix it within the iteration.
- A failure attributable to no single Worker (dependency resolution, or an interaction between two individually-correct changes) belongs to the Iteration, not to a task. It counts against no task's attempts; three failures to resolve it abandon the whole Phase.

## Task Decomposition

- Decompose by **incremental working behavior**, not by technical layer or file. Each task must leave
  the feature demonstrably more complete and functioning at some observable level — not merely a
  helper function, internal utility, or scaffold with nothing yet wired to it.
- Rule of thumb: phrase the task's acceptance as "the user/system can now observe/do X." If a task
  would only compile, or exist with no caller yet, it isn't a task-sized checkpoint — fold it into the
  task that first makes it observable.
- Example — a notification-on-launch feature:
  - Wrong (layer-based): "write NotificationUtil.kt" / "write PermissionUtil.kt" / "wire into
    MainApplication" / "add tests" / "update README" — nothing is independently demonstrable until
    the wiring task lands; each of the first three pays full review/checkpoint overhead for no
    observable behavior of its own.
  - Right (checkpoint-based): "app can request notification permission on launch" (demonstrable: the
    permission dialog appears) → "app can send a notification on demand" (demonstrable: calling it
    posts a real notification) → "app sends the notification automatically on every cold start"
    (demonstrable: the full PRD behavior, end-to-end).
- This does not mean skipping helper functions or good structure — it means a task isn't complete
  until its observable behavior is real, even if implementing it required several private helpers
  along the way. Batch that internal work into the checkpoint task it serves rather than giving it a
  separate task and separate review/checkpoint overhead for no independent behavior.
- Every task carries a **Declared File Scope**: the files it is permitted to write. Determine it during decomposition, because Phase grouping depends on it.

## Model Tier Criteria

Two tiers exist: **Fast** and **Capable**, mapped to concrete model identifiers in `.harness/loop/models.json` — the only place a vendor model name appears. `ENGINE.md` and this file never name one directly.

**Always Capable, no exception:** the Reviewer, the Verifier, the Orchestrator (the top-level Iteration itself, in every capacity), and every bootstrap fan-out analysis role (ADR-009). These are judgment-heavy roles by definition; tiering applies only to Worker implementation.

**A Worker's task may be classified Fast only if all of the following hold**, assessed by the arm's-length planning roles at bootstrap or Phase re-grouping — never by the Worker itself, and never by the role that proposed the task:

- its Declared File Scope is bounded and contains no shared/integration file (those already belong to no Worker, per ADR-008);
- its acceptance criteria are exactly checkable — a literal output string, an exit code, an existing pattern to extend — not an open-ended judgment call ("well-structured", "handles edge cases" without enumerating them);
- it embeds no architecture decision, no new external dependency, no new cross-module contract.

Everything else defaults to **Capable**. When genuinely uncertain, classify Capable — the cost of a wrong Fast classification is a wasted attempt at the wrong tier; the cost of a wrong Capable classification is a few cents.

**A failed Fast-tier attempt escalates the task to Capable for its remaining attempts** (`ENGINE.md` §8) — mechanical, not re-judged, and free: it does not consume an extra attempt beyond the normal three.

## Phase Grouping

- A **Phase** is a set of tasks executed by one Iteration. It may hold one task or several.
- A task may join a Phase only if it has no unmet dependencies, is not blocked by a queued decision, does not depend on an abandoned task, and its Declared File Scope is **disjoint from every other task in the Phase**.
- **Maximum 3 tasks per Phase.** This is a tunable, not a truth: the Iteration's context grows by one Brief out and one manifest back per Worker, on top of the combined diff, build output, and review. Measure and adjust it. The platform also caps concurrent subagents — `subagent_stats.refused.concurrency_limit` in the Runtime's raw log reveals the real ceiling, so discover it rather than assuming this number is achievable.
- Files shared between tasks — navigation tables, route registries, manifests, dependency and lock files — belong to **no** Worker's scope. The Iteration makes those edits itself after merging. Two independent screens still both touch the router; that is the conflict a plan calls absent and a diff reveals.
- Grouping tasks into Phases is what reduces the number of Iterations, and each Iteration is where orientation cost is paid. Running a Phase's Workers concurrently reduces wall-clock only, and spends the account's usage window faster. When quota is the binding constraint rather than time, prefer sequential Workers within the Phase.

## Tier Classification Rules

Classify a plan mutation as the **highest** tier that applies:

- Touches `PRD.md` or approved `DoD.md` semantics → **Tier 3**.
- Changes architecture (layer boundaries, module responsibilities, technology choices, public contracts), changes the overall execution strategy, restructures a large part of the plan (rule of thumb: more than a third of open tasks), or requires a new Capability → **Tier 2**.
- Everything else (split/merge/reorder/re-group/add-prerequisite/remove-obsolete within the approved shape) → **Tier 1**, logged.

When genuinely uncertain between tiers, choose the higher tier.

## Decision Queue Criteria

Queue a decision when: architecture must change; intent must change; a capability is needed; product information is missing from the PRD/DoD; a security risk is discovered; a task remains blocked after reconciliation.

Queueing a decision does **not** stop the run. Mark the tasks that decision blocks, then work on tasks it does not block. `ESCALATE` is reported only when no executable task remains.

Every queued entry must name the tasks it blocks. That naming is the safety property: a blocked task is unselectable, which is what makes it impossible to build on an unanswered question. An entry naming no tasks is a defect.

Never queue a decision merely because implementation is difficult. Difficulty is your job.

## Constraints vs Reference in Knowledge

`.harness/knowledge/PROJECT.md` splits by one question: **if a Worker ignored this, would the result
be wrong?**

- **Constraint** — yes. A trap: "never X here, because Y". Carried **verbatim into every Worker
  Brief**, never filtered (ADR-016). The Fresh-Context Review checks the diff against every one, and
  a violation is a blocking finding rather than an opinion.
- **Reference** — no. Build commands, layout, naming, conventions. Violating one is untidy. Filtered
  into a Brief as the task needs.

Rules that keep the mechanism working:

- **Few and terse.** If everything is a Constraint, the Brief becomes a wall of text with the
  important line buried — which is the exact failure Constraints exist to prevent. One earns its
  place by having cost something: a defect, a failed attempt, a review finding.
- **Cite evidence** (`file:line`), so it can be checked and so it can be retired.
- **Delete it when it stops being true.** Knowledge is a cache and the codebase wins; a stale
  Constraint misleads worse than a missing one.
- **Prefer a lint rule or a test wherever the trap can be mechanised.** Constraints are for traps
  that resist mechanisation — no lint rule expresses "this colour is invisible against the
  background this app happens to paint".
- **Record it in the same checkpoint that discovered it.** A delay of one Phase is enough to ship
  the defect; that is measured, not hypothetical.

A Constraint outranks a literal reading of an acceptance criterion. Where they conflict, the Worker
follows the Constraint and says so — complying with the words while producing something broken is
not compliance.

## Worker Standards

- A Worker implements exactly one task, writes only files inside its Declared File Scope, and holds **no git, build, or test capability**.
- A Worker's Brief carries the *status* of other tasks, never their content or implementation reasoning, plus pointers to interfaces earlier Phases created. It reads the repository itself when it needs an interface.
- A Worker's report is a **manifest, not a payload**: files written, behavior now working, what it could not do, what it learned. The Iteration reads the diff from git, never from the report.
- Scope is verified, not trusted: reported file sets must be pairwise disjoint, contained in their Declared File Scope, and their union must match `git status`. A violation means the plan was wrong to call the tasks independent.

## Verification Class Criteria

Every DoD criterion is either `machine` or `human` (ADR-015). The split is not usually a judgement call:

| `machine` | `human` |
|---|---|
| Business logic: CRUD correctness, date arithmetic, validation, scoping rules | Appearance: colour, contrast, readability, spacing, alignment |
| Behaviour and flow: an action reaches the intended screen, state transitions are correct, data survives a restart | Whether a control can actually be **seen and found** |
| The app builds **and starts without crashing**, each screen opens without throwing | Whether the result looks like what was asked for |

Building is not running. `assembleDebug` proves the code type-checks and says nothing about whether a
screen renders. Where a device or emulator is available, launch-and-open-each-screen is `machine` and
should be written that way; where it is not, that is a `human` item.

**A user-facing capability usually needs one criterion of each class.** "The user can delete a note"
is two claims: the record is removed (`machine`), and the delete control is visible and reachable
(`human`). Asserting only the first is how a correctly-wired button ships rendered invisible.

**A DoD covering user-facing behaviour with zero `human` criteria is a defect.** Zero does not mean
the requirement was specified unusually well; it means the criteria are measuring a layer beneath the
one the user experiences.

When uncertain, classify `human`. The costs are asymmetric: over-classifying costs one look,
under-classifying ships something nobody can see.

## Review Standards

Fresh-Context Review checks, in priority order: correctness, security, edge cases, architecture conformance, duplication, maintainability, testability, performance.

Finding severities:

- **Critical** — wrong behavior, data loss, security hole, DoD violation. Blocks task completion; fix in this iteration or file a blocking task.
- **Major** — likely future defect or architectural erosion. File a task.
- **Minor** — style, naming, polish. Fix opportunistically or record; never let minors block progress.

Findings recorded but not fixed belong in the Issues Report — otherwise they vanish when `.harness/run/` is removed.

## Evidence Requirements

A claim without evidence is not a fact. Task completion requires recorded evidence per ENGINE.md §6.7 and §6.10. "It should work" is never evidence. Evidence must be reproducible from the checkpoint: command + observed output.

## Capability Risk Classes

- **Low-risk (baseline, permanent, ships with the runtime):** reading repository files; `git status/diff/log/add/commit/checkout/branch` local operations; creating and editing files inside the consumer repository (excluding protected paths).
- **Standing (per-repository, approved at the DoD gate, lives in Knowledge):** the repository's verified toolchain — build, test, lint, dependency install. Pushing the Loop Branch also belongs here when granted, since it applies to every checkpoint of the run.
- **High-risk (goal-scoped by default, always explicit):** deletion commands; **network access, including `git push`**; process/system management (`docker`, `adb`, `kubectl`, service control); anything touching paths outside the repository; anything irreversible.
- **Analyst-denied always:** write, edit and shell of any kind. The bootstrap fan-out roles (survey, DoD proposal, decomposition, critique, conflict analysis) propose; the Iteration alone authors the plan, so they need no write access and are given none.
- **Worker-denied always:** git of any kind, build, test, and any write to `.harness/run/` or `.harness/knowledge/`. A Worker that could write shared state would break the single-writer rule that makes concurrent Workers safe. These limits are the `tools:` list in `.harness/loop/agents/`, enforced by the harness rather than by instruction.

Protected paths (never writable by the engine, enforced by runtime deny rules): `.harness/loop/`, all Capability Ledgers, generated permission settings, runtime configuration.

## Reconciliation Rules

- Every discovery is classified in the iteration it was made. Deferring classification is itself a violation.
- Operational discoveries (commands, environment quirks, conventions) update `.harness/knowledge/` in the same checkpoint.
- Ambiguity in the PRD/DoD is never resolved by guessing on behalf of the human: minor ambiguity → record the assumption in `STATE.md` and the Issues Report (auditable, reversible); behavior-defining ambiguity → queued decision.

## Git Conduct

- All work on the Loop Branch. Never the default branch, never merge, never rewrite history (`--force`, rebase) — the branch is an audit trail.
- `git push` of the Loop Branch is permitted only under a granted capability, and only for that branch. Pushing makes a mid-run machine failure survivable and lets the human review from elsewhere; it is never a step toward merging, which stays a human act.
- One atomic checkpoint commit per iteration: code + `.harness/run/` + `.harness/knowledge/` together.
- Commit messages: first line `loop(phase-<n>): <what a human would call this>` — a plain-language summary, not a list of task ids. Body lists what each Worker did, the evidence summary, and amendments made.
