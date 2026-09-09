# POLICIES

> Generic engineering policy shipped with Foreman. Identical in every consumer repository — project-specific facts belong in `knowledge/`, never here.

---

## Retry Policy

- Retry a failed approach only when the probability of success has increased: new information, a different strategy, a corrected assumption. Never retry identical work.
- Maximum 3 attempts per task across all iterations (attempts are counted in the task file). The 3rd failure is a discovery that must reconcile to Escalation, not a 4th attempt.
- A build/test failure caused by a fixable defect in your own new code is a fix, not a retry — fix it within the iteration.

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

## Tier Classification Rules

Classify a plan mutation as the **highest** tier that applies:

- Touches `PRD.md` or approved `DoD.md` semantics → **Tier 3**.
- Changes architecture (layer boundaries, module responsibilities, technology choices, public contracts), changes the overall execution strategy, restructures a large part of the plan (rule of thumb: more than a third of open tasks), or requires a new Capability → **Tier 2**.
- Everything else (split/merge/reorder/add-prerequisite/remove-obsolete within the approved shape) → **Tier 1**, logged.

When genuinely uncertain between tiers, choose the higher tier.

## Escalation Criteria

Escalate when: architecture must change; intent must change; a capability is needed; product information is missing from the PRD/DoD; a security risk is discovered; a task remains blocked after reconciliation; failure is irrecoverable within your authority.

Never escalate merely because implementation is difficult. Difficulty is your job.

## Review Standards

Fresh-Context Review checks, in priority order: correctness, security, edge cases, architecture conformance, duplication, maintainability, testability, performance.

Finding severities:

- **Critical** — wrong behavior, data loss, security hole, DoD violation. Blocks task completion; fix in this iteration or file a blocking task.
- **Major** — likely future defect or architectural erosion. File a task.
- **Minor** — style, naming, polish. Fix opportunistically or record; never let minors block progress.

## Evidence Requirements

A claim without evidence is not a fact. Task completion requires recorded evidence per ENGINE.md §10. "It should work" is never evidence. Evidence must be reproducible from the checkpoint: command + observed output.

## Capability Risk Classes

- **Low-risk (baseline, permanent, ships with the runtime):** reading repository files; `git status/diff/log/add/commit/checkout/branch` local operations; creating and editing files inside the consumer repository (excluding protected paths).
- **Standing (per-repository, approved at the DoD gate, lives in Knowledge):** the repository's verified toolchain — build, test, lint, dependency install.
- **High-risk (goal-scoped by default, always explicit):** deletion commands; network access beyond dependency resolution; process/system management (`docker`, `adb`, `kubectl`, service control); anything touching paths outside the repository; anything irreversible.

Protected paths (never writable by the engine, enforced by runtime deny rules): `.loop/`, all Capability Ledgers, generated permission settings, runtime configuration.

## Reconciliation Rules

- Every discovery is classified in the iteration it was made. Deferring classification is itself a violation.
- Operational discoveries (commands, environment quirks, conventions) update `knowledge/` in the same checkpoint.
- Ambiguity in the PRD/DoD is never resolved by guessing on behalf of the human: minor ambiguity → record the assumption in `STATE.md` (auditable, reversible); behavior-defining ambiguity → Escalation Request.

## Git Conduct

- All work on the Loop Branch. Never the default branch, never push, never merge, never rewrite history (`--force`, rebase) — the branch is an audit trail.
- One atomic checkpoint commit per iteration: code + `.ai/` + `knowledge/` together.
- Commit messages: first line `loop(<task-id>): <what changed>`; body lists evidence summary and amendments made.
