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

## User-Interface Defects

Every line here was earned by a real failure that a passing build, a passing test suite, and a
fresh-context review all missed. They are **Critical**, not polish: each one makes a stated
requirement untrue while every automated check stays green.

- **A marker drawn on a filled shape must contrast with that fill, not repeat it.** A dot painted
  in the same role as the container it sits on is invisible. Check the *combined* states, not each
  in isolation — the broken case is usually the overlap (selected *and* flagged, today *and* has
  content).
- **A screen holding a variable-length list must scroll.** Fixed-height layouts silently push
  content — including the controls for adding more — off the bottom, so the requirement fails
  precisely for the users who rely on the feature most.
- **Every list needs an empty state.** A blank region reads as a load failure, not as "nothing
  here yet". If a component defers this to its caller, verify the caller actually does it.
- **A destructive action needs a confirmation step**, and the confirming control must be visually
  distinct from the safe one. One-tap irreversible deletion is a defect, not a shortcut.
- **Text that can exceed its container needs a defined overflow behaviour** — wrap, expand, or an
  affordance to read the rest. Truncating to one line with no route to the full value loses data
  the user entered.
- **Colour must come from the theme, never hardcoded.** Hardcoded values work only by coincidence
  with whatever background happens to sit underneath, and fail as soon as that changes. If a
  colour scheme is declared, fill in **every** role it defines: partial schemes leave components
  reaching for roles nobody chose.

Note also that a component preview rendered outside the app's real theme and ground colour proves
nothing about what a user sees — this is exactly how hardcoded colours survive review.

## Evidence Requirements

A claim without evidence is not a fact. Task completion requires recorded evidence per ENGINE.md §10. "It should work" is never evidence. Evidence must be reproducible from the checkpoint: command + observed output.

**A requirement no available command can prove is a gap to report, never a criterion to drop.**
When the DoD carries a requirement whose satisfaction cannot be observed in any command's output —
anything about appearance, contrast, layout, or what a user can actually perceive — say so
explicitly, and take one of two routes:

- propose the capability that would make it provable (for a UI, a host-side screenshot or snapshot
  test usually runs in the existing test task with no device); or
- escalate that the criterion needs human inspection, and record it as such.

What must not happen is the third route: quietly treating the machine-checkable subset as the whole
requirement. That subset passes, the fresh-context reviewer has no standard to judge the rest
against, and the run reports a verified `DONE` over a requirement that is untrue. A reviewer cannot
find what the Definition of Done never defined — more review passes do not fix this, only a
criterion that can fail does.

## Capability Risk Classes

- **Low-risk (baseline, permanent, ships with the runtime):** reading repository files; `git status/diff/log/add/commit/checkout/branch` local operations; creating and editing files inside the consumer repository (excluding protected paths).
- **Standing (per-repository, approved at the DoD gate, lives in Knowledge):** the repository's verified toolchain — build, test, lint, dependency install.
- **High-risk (goal-scoped by default, always explicit):** deletion commands; network access beyond dependency resolution; process/system management (`docker`, `adb`, `kubectl`, service control); anything touching paths outside the repository; anything irreversible.

Protected paths (never writable by the engine, enforced by runtime deny rules): `.loop/`, all Capability Ledgers, `knowledge/DOMAIN.md`, generated permission settings, runtime configuration.

## The Two Knowledge Files

`knowledge/` holds two files with different owners and **opposite** conflict rules. Applying one file's rule to the other is a defect.

| | `knowledge/PROJECT.md` | `knowledge/DOMAIN.md` |
|---|---|---|
| Content | Verified toolchain commands, conventions, environmental facts about *this repository* | Domain rules, formulas, algorithms, business and regulatory invariants |
| Owner | Engine (human-editable, no gate) | **Human only** — engine may read and propose, never write |
| Conflicts with the codebase | **Codebase wins** — it is a cache of facts about the code, so the code corrects it | **This file wins** — the code is an attempt at the rule; a difference is a defect in the code |
| Lifetime | Per repository, cumulative | Per repository, cumulative |

Neither file is a place for knowledge about a technology stack in general (platform API behaviour, framework idioms). That is not truth about *this* repository, nothing here can verify it, and it goes stale with no mechanism to correct it — see ADR-007.

## Reconciliation Rules

- Every discovery is classified in the iteration it was made. Deferring classification is itself a violation.
- Operational discoveries (commands, environment quirks, conventions) update `knowledge/PROJECT.md` in the same checkpoint.
- A conflict between the codebase and `knowledge/DOMAIN.md` is a **defect report**, never a cache correction. Fix the code inside the current task or file a task; if you believe the rule itself is wrong or incomplete, escalate and propose the change.
- Ambiguity in the PRD/DoD is never resolved by guessing on behalf of the human: minor ambiguity → record the assumption in `STATE.md` (auditable, reversible); behavior-defining ambiguity → Escalation Request.
- **Earn each line.** Record a lesson only when a real failure demonstrated it — a broken build, a failing test, a review finding, a denied command. A lesson merely inferred is noise, and noise in files read every iteration makes earned lines matter less. Remove a line once the model no longer needs it.

## Git Conduct

- All work on the Loop Branch. Never the default branch, never push, never merge, never rewrite history (`--force`, rebase) — the branch is an audit trail.
- One atomic checkpoint commit per iteration: code + `.ai/` + `knowledge/` together.
- Commit messages: first line `loop(<task-id>): <what changed>`; body lists evidence summary and amendments made.
