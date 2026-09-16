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

**Always Capable, no exception:** the Reviewer, the Verifier, and every bootstrap fan-out analysis role (ADR-009). These are the roles that decide whether work is *correct*, and none of them may run below Capable.

**The Orchestrator runs at Fast in its ordinary capacity, and at Capable whenever it is the Verifier (§11).** The Runtime chooses this before the invocation starts and passes `--model` itself, because one model is fixed for a whole invocation and the Iteration cannot switch its own mid-session. `STATE.md`'s DONE-candidate is the signal, the same one §6.3 branches on.

This line was earned, not reasoned: the Calendar-Note alarms run passed `--model` **never**, so the top-level session inherited the CLI default for the entire run. 979 of 1,215 Orchestrator messages ran below Capable, and the Verifier — this table's one "no exception" — re-proved all 36 DoD criteria on the cheaper model. Meanwhile the Workers, the only role tiering was supposed to touch, ran at Capable throughout. The tier system was not merely unenforced, it was inverted.

**A Worker's task may be classified Fast only if all of the following hold**, assessed by the arm's-length planning roles at bootstrap or Phase re-grouping — never by the Worker itself, and never by the role that proposed the task:

- its Declared File Scope is bounded and contains no shared/integration file (those already belong to no Worker, per ADR-008);
- its acceptance criteria are exactly checkable — a literal output string, an exit code, an existing pattern to extend — not an open-ended judgment call ("well-structured", "handles edge cases" without enumerating them);
- it embeds no architecture decision, no new external dependency, no new cross-module contract.

Everything else defaults to **Capable**. When genuinely uncertain, classify Capable — the cost of a wrong Fast classification is a wasted attempt at the wrong tier; the cost of a wrong Capable classification is a few cents.

**If nothing is ever classified Fast, the tier is misconfigured, not the criteria.** Measured on the Calendar-Note alarms run: 7 of 7 tasks Capable, and the Fast model consumed 6,363 input tokens and one cent across the whole run. The criteria above are correctly cautious; a planning role that will not stake a Kotlin/Compose task on the Fast tier is behaving well. The fix belongs in `models.json` — raise what Fast maps to until a cautious planner can choose it — never in loosening these three conditions.

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

## Domain Knowledge is human-owned and outranks the codebase

`.harness/knowledge/DOMAIN.md` is optional, and absent rather than stubbed when a project has none.
It holds durable truth about the problem domain - rules, formulas, algorithms, business and
regulatory invariants - and its conflict rule is the **inverse** of `PROJECT.md`'s:

| | `PROJECT.md` | `DOMAIN.md` |
|---|---|---|
| Owner | Engine (human-editable, no gate) | **Human only** - engine reads and proposes, never writes |
| On conflict with the codebase | **Codebase wins**; it caches facts about the code | **This file wins**; the code is an attempt at the rule |

Applying one file's rule to the other is a defect. A formula implemented plausibly-but-wrongly
passes the build and passes tests written from the same misreading - the Fresh-Context Review
holding the authoritative rule, rather than the Worker's reasoning, is the only mind placed to catch
it. Give the reviewer every `DOMAIN.md` rule the diff touches.

Engine-immutable is enforced by runtime deny rules, not by asking: a rule enforced by a script is a
rule, a rule living only in a prompt is a wish (ADR-002).

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

### A lesson that is true beyond this repository goes in the Suggestion Box

`SUGGESTIONS.html` carries two tabs — Escalate (a read-only mirror of `ESCALATION.md`) and
Suggestions (this section) — sharing one page (ADR-026). What follows governs the Suggestions tab.

`PROJECT.md` holds truth about **this** repository. Some of what a run learns is not that: it is true
of every repository, or of every repository on this stack. Those belong one tier up (ADR-019) — and
you are denied write access to `.harness/loop/`, correctly, because that tier also records your own
permissions.

So the only tier you *can* write to is the one where a portable lesson does not belong, and writing
it there is how it gets lost. Instead, **propose it**: append an entry to `SUGGESTIONS.html` at the
consumer repository root, and regenerate the page from
`.harness/loop/templates/SUGGESTIONS.template.html`.

What earns an entry:

- **It cost something.** The same bar as a Constraint — a broken build, a failing test, a review
  finding, a denied command. Never a lesson you merely inferred.
- **It would still be true in a repository with none of this code.** If it names a file, a module or
  a convention here, it is a Constraint or a Reference, not a suggestion.
- **It names a destination.** `loop` for doctrine true of every stack; `stack` for a platform pack —
  and when the destination is `stack`, name the platform too (android, backend, frontend, devops, ...),
  matching the `skills/knowledge/<platform>/` pack it would land in. An unlabelled `stack` entry is
  fine with one platform in play and noise the moment a second one is; name it every time regardless.
  Say plainly when something should **stay** — a box that only ever argues for promotion is noise.
- **It carries both explanations.** The technical one, and one a non-specialist can follow. The
  reader is deciding whether to change the product, not debugging with you.

Two rules bound it:

- **You never act on your own suggestion.** It is a proposal to a human, not a plan. Nothing in
  `.harness/loop/` moves because you wrote an entry, and the entry stays until a human resolves it.
- **The file is a report, not state.** It is regenerated, survives the Cleanup Commit like the Issues
  Report, and nothing reads it back — no decision of yours may depend on it.

Say so in your completion or escalation summary when the box changed, and say what changed. An
unread suggestion box is the same as no suggestion box.

### A known defect is always a Constraint, written as an instruction

The sorting question above gives the wrong answer for one kind of fact, and it is the kind that has
already cost a defect. Take something true about the code and **wrong**:

> `CoreLayout.kt` paints a hardcoded black background regardless of `darkTheme`, and no screen
> sources its text colour from `MaterialTheme.colorScheme` — a pre-existing, app-wide pattern.

Ask the question: if a Worker ignored this, would the result be wrong? **No** — it would take its
colours from the theme, which is better. So the literal test files it as a Reference, and a Reference
is a convention to follow. The next Worker reads it and reproduces the defect on purpose. That is not
hypothetical: it is exactly what happened, and it is why the fact must never be recorded in its
descriptive form.

So: **a defect you know about and are not fixing is a Constraint**, phrased as the instruction it
implies, never as the observation it came from.

| Do not write | Write |
|---|---|
| "`CoreLayout` hardcodes its background" | "never take a colour from `CoreLayout`'s pattern — source every colour from the theme (`CoreLayout.kt:34`)" |
| "the repo has no tests for the note mapper" | "do not assume `NoteMapper` is covered — add a test with any change to it" |

The test to apply is not "would ignoring this be wrong" but **"what should a Worker do about it?"**
If the honest answer is *avoid it* rather than *follow it*, it is a Constraint whatever the first
question says.

This is the whole of what ADR-020 protected, kept after the artifact it lived in was retired
(ADR-018). A defect recorded as a fact is read as the local convention, and conforming to it is the
failure.

## Worker Standards

- A Worker implements exactly one task, writes only files inside its Declared File Scope, and holds **no git, build, or test capability**.
- A Worker's Brief carries the *status* of other tasks, never their content or implementation reasoning, plus pointers to interfaces earlier Phases created. It reads the repository itself when it needs an interface.
- A Worker's report is a **manifest, not a payload**: files written, behavior now working, what it could not do, what it learned. The Iteration reads the diff from git, never from the report.
- Scope is verified, not trusted: reported file sets must be pairwise disjoint, contained in their Declared File Scope, and their union must match `git status`. A violation means the plan was wrong to call the tasks independent.

## Verification Class Criteria

Every DoD criterion declares one of **three** classes (ADR-015, ADR-025):

| Class | Who produces the evidence | What closes it |
|---|---|---|
| `machine` | a command | the command's output |
| `machine-then-human` | a command drives it **first**, then a person looks | **the person's signature** |
| `human-only` | nothing can drive it — perception, judgement | the person's signature |

**A machine pre-check never closes a `machine-then-human` criterion.** It exists to stop the human
being the *first* person to find a defect, not to replace them. Earned on a real run: fourteen
`machine` criteria were green, a fresh-context Verifier re-proved every one of them, a machine check
of the criterion in question reported pass — and the human opened the app once and found it broken.

Three rules keep the pre-check honest, and the third is the one that failed:

- **A pre-check that fails is a defect**, reconciled into the run like any other failure, consuming
  the normal attempt budget and abandonable at the third try. It does not become a note for the human.
- **A pre-check that passes is written as "did not fail when driven from state X"**, never as "works".
  The difference is not pedantry: a criterion labelled as machine-verified is read faster, so a
  pre-check that oversells itself makes the human's look *worse* than no pre-check at all.
- **A criterion any command will drive must name the state it is driven from.** The pass above was
  false because the check ran on a device where the permission was already granted, while the
  criterion said *install fresh, grant when asked, then open*. Two different paths; the automated one
  was the one that worked. Name the starting state or automation will quietly pick the easy branch.

The old split still decides which of the three a criterion lands in:

| Closed by a command (`machine`) | Needs a signature (`machine-then-human`, or `human-only` when nothing can drive it) |
|---|---|
| Business logic: CRUD correctness, date arithmetic, validation, scoping rules | Appearance: colour, contrast, readability, spacing, alignment |
| Behaviour and flow: an action reaches the intended screen, state transitions are correct, data survives a restart | Whether a control can actually be **seen and found** |
| The app builds **and starts without crashing**, each screen opens without throwing | Whether the result looks like what was asked for |

Building is not running. `assembleDebug` proves the code type-checks and says nothing about whether a
screen renders.

**A user-facing capability usually needs one criterion of each kind**, and a DoD covering
user-facing behaviour with **zero** criteria needing a signature is a defect. "The user can delete a
note" is two claims: the record is removed, and the delete control is visible and reachable.
Asserting only the first is how a correctly-wired button ships rendered invisible; a zero count does
not mean the requirement was specified unusually well, it means the criteria are measuring a layer
beneath the one the user experiences.

When uncertain, classify for a human signature — `machine-then-human` if anything can drive it,
`human-only` otherwise. The costs are asymmetric: over-classifying costs one look, under-classifying
ships something nobody can see.

### What the environment can do is a fact, and facts go stale

`knowledge/PROJECT.md` caches what this repository can run. **A claim there about the absence of a
capability — no device, no emulator, no `adb`, no container — is re-checked before it is used to
classify a criterion, not trusted because it is written down.** One command settles it.

Earned: a repository's `PROJECT.md` stated "No emulator, no device, no `adb`, no Robolectric — there
is no command here that can prove it", and every run dutifully classed anything needing a running app
as `human`. The claim was false. `adb` was installed, a device was attached, and the project already
had an `androidTest/` source set wired to a working instrumentation runner. Three runs inherited the
note and none re-read the ground under it. An absence is the one kind of claim that rots silently,
because nothing ever fails to remind you of it.

### A perceptual criterion may be `machine` only if it cites the reference image behind it

There is a third way to verify appearance, and it is neither a command's output nor a person at a
screen: **the engine opens the rendered image and judges it.** This is a real act of perception
performed by the machine, and it happened unprompted - an engine recorded reference images, read
them, then perturbed a colour and re-ran validation to confirm the harness could actually go red.

It is admissible, under one condition: **the render must be pinned by a committed reference image**,
so the judgement made once is defended by command every time afterwards.

```
engine opens the render, judges "the dot is legible on the picked fill"   <- ONCE, unreproducible
     the render is pinned as a reference image and committed
validateDebugScreenshotTest                                    <- FOREVER, red on any drift
```

The perception is the weak step: it is a judgement, not a measurement, two invocations may read the
same image differently, and nothing reproduces it from the checkpoint - which is what evidence
requires. Pinning confines that weakness to a single moment and locks a reproducible check in front
of it.

So the class stays `machine`, and the criterion must **name the reference file**. A criterion that
claims `machine` for an appearance clause without citing one has not produced evidence; it has
produced an opinion, and belongs in `human`.

Two limits, neither of which the prose can enforce:

- **Never the sole evidence.** A pinned render proves what it renders. It does not prove the feature
  works, and a screenshot test passing beside a failing unit test proves only that the wrong thing
  was drawn consistently.
- **Never for anything a person's safety or comprehension depends on.** Those stay `human`.

**The baseline must be out of reach.** Where a task exists that re-records the reference images
(`updateDebugScreenshotTest` and its equivalents), it is **withheld from the standing ledger**. An
engine holding it, facing a red screenshot test, has a one-command route to re-recording wrong output
as correct. Recording a *new* reference is the safe half; overwriting a *currently-failing* one is
not, and a command matcher cannot tell them apart - so a baseline change is an Escalation Request and
a goal-scoped grant, never a standing rule. This limit is the only part of the contract that is
mechanically enforceable, and the rest of this section is worth nothing without it.

## Review Standards

Fresh-Context Review checks, in priority order: correctness, security, edge cases, architecture conformance, duplication, maintainability, testability, performance.

Finding severities:

- **Critical** — wrong behavior, data loss, security hole, DoD violation. Blocks task completion; fix in this iteration or file a blocking task.
- **Major** — likely future defect or architectural erosion. File a task.
- **Minor** — style, naming, polish. Fix opportunistically or record; never let minors block progress.

Findings recorded but not fixed belong in the Issues Report — otherwise they vanish when `.harness/run/` is removed.

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

A claim without evidence is not a fact. Task completion requires recorded evidence per ENGINE.md §6.7 and §6.10. "It should work" is never evidence. Evidence must be reproducible from the checkpoint: command + observed output.

**Evidence is written to a file and read in summary; it is not pasted whole into the transcript.**
Redirect a build, test or lint run to a file under the run directory, then read back only what
decides the question: the exit code, the summary line, the failing cases. Cite the file so the
Reviewer and the Verifier can open the whole thing.

Nothing about the standard changes: the command still has to actually run, unpiped (see below), the
output still has to exist on disk, and a claim still has to be reproducible from the checkpoint. What
changes is how many times that output gets paid for. Every token placed in a transcript is re-read on
every later turn of the same invocation, so a full Gradle log pasted at turn 20 is charged again at
turns 21 through 146.

Measured on the Calendar-Note alarms run: **143 million cache-read tokens across 645 turns, 222K of
context carried per turn on average and 767K at the worst session — 55% of the entire bill.** The
same growth is what makes a single iteration expensive enough to matter: one 33-minute iteration took
the five-hour quota window to 97%, and the loop then sat idle for 2h38m waiting for it to reset. Over
half the run's wall clock — 3.4 of 6.5 hours measured — was the engine not running at all.

**Never take a piped command's exit code as evidence.** `./gradlew build 2>&1 | tail -20` exits **0
when the build failed**, because the exit status belongs to `tail`. This is not hypothetical: a real
`BUILD FAILED` was first read as a pass this way, and the failure direction is the dangerous one - it
does not stop the run, it lets the run continue believing something false, past every reviewer whose
job assumed the build was green.

Prefix the pipeline - `set -o pipefail; <command> | tail -20` - or run it unpiped and record the
tool's own verdict line. `Bash(set -o pipefail)` is a baseline capability precisely so the first form
is always available; it executes nothing and only makes a pipeline report the first non-zero status
in it. `${PIPESTATUS[0]}` and redirecting to a file are both refused by the permission matcher
(verified 2026-09-11), so neither is an option.

**Read a result file only from a run whose own success line you saw.** Asking for four tasks in one
command does not mean four tasks ran: the first failure aborts the rest, and the results file from
the *previous* invocation is still on disk with its old counts and `failures="0"`. Reading it
produces a confident, wrong "the new tests pass", and the tell is subtle — the counts did not go
**up** after tests were added. Treat an unchanged count as a failure to run, not as a pass.

**A green subset of commands is not a green tree.** Know which commands cover which source sets, and
which cover none. A build task and a unit-test task can both report success while a third source set
does not compile at all — changing a signature the third one calls is enough. When you change
anything shared, run the command set that covers the whole tree, and say which commands that was.
"Everything I ran passed" is only evidence if you can name what you did not run.

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

**Reading a file out of an earlier commit or another branch is not symmetric across paths.**
`git show <ref>:<path>` behaves for ordinary source paths. For a path beginning with a dot-directory
— `.harness/**` included, which is every path this loop writes — Git Bash rewrites `ref:path` into
`ref;path` and fails with *"unknown revision or path not in the working tree"*. That message reads
exactly like the file is absent when it is present, so the natural conclusion is the wrong one: that
the history holds nothing.

Prefix those reads with `MSYS_NO_PATHCONV=1`, or resolve the ref to a SHA with `git rev-parse` first
— the SHA form is unaffected. Never conclude a record is missing from that error alone; re-read it
the other way before believing it.
