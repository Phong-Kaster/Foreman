# Loop Runtime

The vocabulary of the Loop Runtime: a portable execution engine, installed into consumer repositories either as a Claude Code skill or by copying `.harness/loop/` directly, that turns a feature PRD into verified working software with minimal human intervention during coding.

## Language

**Runtime**:
The thin, intentionally dumb outer script that compiles the Capability Ledger into permission settings, invokes Claude Code, reads the Execution Status, and decides whether to invoke again. It is the enforcement plane: purely mechanical, never judgmental. Contains no planning, reconciliation, or scheduling logic.
_Avoid_: Harness, orchestrator, scheduler

**Skill**:
The `/loop-runtime` Claude Code skill — the recommended surface for installing and operating the loop. It carries its own copy of `.harness/loop/`'s contents (spec, policies, templates, runtime script) and materializes them at the consumer repository root; stages the human's requirement (inline text or a document path) as `PRD.md`; launches and supervises `run.ps1` live instead of leaving it to a terminal; mediates every Escalation Request as ordinary conversation instead of a file the human must open and edit; and reports a Roll-up Summary at completion. It adds no authority of its own — every Capability it exercises still traces back to a ledger entry the human approved through the same Trust Chain.
_Avoid_: Wrapper, launcher (undersells that it also supervises and summarizes), plugin (V1 ships as a skill, not a Claude Code plugin — see ADR notes on invocation namespacing)

**Execution Engine**:
The AI process (one Claude Code invocation) governed by ENGINE.md that performs all reasoning: task selection, implementation, verification, reconciliation.
_Avoid_: Agent, assistant, bot

**Iteration**:
One Runtime invocation of the Execution Engine: reconstruct context from the Resume Block and durable artifacts, execute exactly one Phase, persist all changes as one Stable Checkpoint, return one Execution Status. An Iteration is not one task — a Phase may hold several.
_Avoid_: Task, step, turn

**Phase**:
A set of tasks with no unmet dependencies and no overlapping Declared File Scope, executed by a single Iteration. A Phase may hold one task or many. Grouping tasks into Phases is what reduces the number of Iterations — and therefore the orientation cost paid per Iteration; running a Phase's tasks concurrently only reduces wall-clock. Not to be confused with the run's **Stage**.
_Avoid_: Batch, sprint, stage, round

**Model Tier**:
One of two capability levels — Fast or Capable — assigned to a Worker's task at planning time by the arm's-length fan-out roles (never by the Worker itself), and always Capable for the Reviewer, the Verifier, and the Orchestrator. A failed Fast-tier attempt escalates the task to Capable for its remaining attempts. Named abstractly on purpose: neither `ENGINE.md` nor `POLICIES.md` ever names a vendor model.
_Avoid_: Model, model choice (too generic — always say which tier)

**Model Tier Map**:
`.harness/loop/models.json`, the one file mapping a Model Tier name to a concrete vendor model identifier. The engine reads it, never writes it. Porting to another engine means editing this file, not the specification — the same adapter-boundary principle as ADR-006, applied to model naming.
_Avoid_: Model config, model settings (implies something richer than a two-entry mapping)

**Stage**:
Where a run currently sits in its lifecycle: bootstrap, executing, done-candidate, or escalated. Recorded in `STATE.md`. Named `Phase` in V1 and renamed to free that word for the task group (ADR-008).
_Avoid_: Phase (its former name), state (overloaded)

**Worker**:
A clean-context subagent dispatched by the Iteration to implement exactly one task of a Phase, in place in the single working directory, within its Declared File Scope. A Worker holds no git, build, or test capability — enforced by its agent definition, not by instruction — so the Iteration remains the sole writer of state and the sole committer.
_Avoid_: Agent (ambiguous), sub-engine, parallel engine

**Declared File Scope**:
The set of files a Worker is permitted to modify, assigned by the Iteration before dispatch and verified after the Worker reports. It serves two purposes: preventing collisions between concurrent Workers, and attributing a build failure to exactly one Worker so it can be re-dispatched with the error. Files shared between tasks — navigation tables, route registries, manifests — are never in a Worker's scope; the Iteration wires them itself.
_Avoid_: File lock, ownership, partition

**Worker Brief**:
The minimal context handed to a Worker: its own task, its Declared File Scope, the *status* of other tasks (never their content or their reasoning), pointers to interfaces earlier Phases created, and the conventions it needs. Its return handoff is a manifest — files written, behavior now working, what it could not do — never a payload; the Iteration reads the diff from git.
_Avoid_: Prompt, context dump, handoff (that's the return direction only)

**Resume Block**:
The small artifact each Iteration writes at its end containing exactly what the next Iteration needs to orient: current Stage, the next Phase's tasks and their Declared File Scopes, queued-decision count, abandoned task ids, verified build/test commands. A derived cache, never a source of truth — where it disagrees with the task files or git, it loses, and Recover always goes to ground truth.
_Avoid_: Memory, cache (alone), summary, context file

**Decision Queue**:
The durable queue of Escalation Requests awaiting human decision. Each entry names the tasks it blocks — the rule that makes deferral safe, because a blocked task becomes unselectable rather than merely unanswered. Replaces V1's "at most one pending Escalation Request": the engine parks a question and continues with unrelated work instead of stopping.
_Avoid_: Inbox, backlog, blocker list

**Abandoned task**:
A task marked permanently incomplete after failing its third attempt, together with every task transitively depending on it, which are marked unreachable rather than attempted. Abandonment is not failure of the run: the loop continues on unrelated work and reports the abandonment in the Issues Report. A run containing an abandoned task can never reach `DONE`.
_Avoid_: Failed task, skipped, dropped

**Issues Report**:
The durable, issues-only artifact regenerated every Iteration and living outside `.harness/run/` so it survives the Cleanup Commit: abandoned tasks with their three failure reasons, queued decisions awaiting the human, review findings noted but not fixed, and recorded assumptions. It carries no narrative of what succeeded — that is what the commit messages are for.
_Avoid_: Report, summary, changelog, roll-up (that's the Skill's end-of-run branch table)

**Execution Status**:
The single value the engine must produce at the end of every successful invocation: CONTINUE, DONE, ESCALATE, or FAILED. The transport (status file, stdout, SDK response…) is an implementation detail, never part of the contract. V1 uses a status file.
_Avoid_: Exit code, result, verdict

**ESCALATE**:
Execution Status meaning the engine is healthy but can make no further progress without a human decision. Reported when no executable task remains and the Decision Queue is non-empty or tasks were abandoned — a batch at the end of a run, not an interruption at the first question (ADR-007). Asks the human for decisions.
_Avoid_: Blocked, paused

**FAILED**:
Execution Status meaning execution itself is broken (environment problems, repository corruption, exhausted resources). Asks the human for repair.
_Avoid_: Error, crashed (a Crash is specifically the absence of any status)

**Capability**:
A scoped, auditable permission grant: intent (why), command (what), resource scope (where), lifetime (how long). Capabilities never silently accumulate, and the default lifetime is goal-scoped — expiry with `.harness/run/` is automatic; reuse requires a new Escalation Request. Permanent capabilities (baseline read/git-local shipped with the runtime; per-repo toolchain standing in Knowledge) represent long-lived policy and always require separate explicit approval. Approval may reduce scope or lifetime, never expand it.
_Avoid_: Permission (as a permanent grant), allowlist entry

**Capability Ledger**:
The durable, human-approved source of truth for Capabilities, split across the three lifecycle layers (baseline in `.harness/loop/`, standing in `.harness/knowledge/`, scoped in `.harness/run/`). Engine-immutable: protected by deny rules the runtime always appends. The compiled permission settings are a build artifact regenerated by the runtime every Iteration — never a source artifact.
_Avoid_: Settings file, permission config (that's the build artifact)

**Trust Chain**:
Human → Capability Ledger → Runtime Compiler → Permission Settings → Engine. Every privilege expansion crosses a human approval boundary; the governed component never enforces or expands its own constraints.
_Avoid_: Security model (this is a guardrail against accidents and drift, not a boundary against an adversarial engine — containment is the VM path)

**Loop Branch**:
The dedicated git branch a run lives on (e.g. `loop/<prd-slug>`), created at bootstrap. Every Worker and every checkpoint of a run shares this one branch. The engine never touches the default branch and never merges — merging is a human act, always. It may push this branch, and only this branch, under an explicitly granted Capability. A catastrophic run is discarded with a branch delete.
_Avoid_: Feature branch (human workflow), working copy

**Cleanup Commit**:
The final commit of a run, created only after fresh verification passes. It removes `.harness/run/` from the branch tip so the mergeable state contains the implementation, durable Knowledge, the completion summary, and verification evidence — never execution state. `.harness/run/` is the loop's memory while it works; it is not the product the human merges. Its full history stays in the branch's commits for audit.
_Avoid_: Squash, final commit (generic)

**Escalation Request**:
The durable artifact the engine persists whenever it requires human input: the question, context, options considered, the engine's recommendation, the tasks it blocks, and space for the human's decision *and rationale*. Persisted into the Decision Queue rather than halting the run; consumed and archived by a later fresh invocation. The "at most one pending" limit of V1 is retired (ADR-007). The artifact name (`.harness/run/ESCALATION.md`) is an implementation detail.
_Avoid_: Question file, blocker, ticket

**Crash**:
An engine invocation that ends without producing any Execution Status. Only the Runtime can detect it — an engine cannot supervise its own death.
_Avoid_: Failure (that's FAILED, which is reported deliberately)

**Watchdog**:
The one policy the Runtime owns: how to react to a Crash (re-invoke up to a bounded number of consecutive crashes, then stop). All other policy lives in the engine.
_Avoid_: Supervisor, monitor

**Stable Checkpoint**:
A verified execution state that is safe to resume from — a fresh Iteration can continue using only durable artifacts. One Iteration produces exactly one Stable Checkpoint. A git commit is a persistence mechanism for a checkpoint, not its definition; git operations belong to the engine, never the runtime.
_Avoid_: Commit (as a synonym), savepoint

**PRD**:
The human-owned product intent: business objective, requirements, constraints. The immutable source of intent for one run of the loop; only the human edits it. Lives at the consumer repository root as `PRD.md` — there is no separate GOAL.md artifact.
_Avoid_: Goal file, spec, requirements doc

**Bootstrap**:
The one-time process that reads `PRD.md`, generates the Definition of Done, and initializes `.harness/run/`. Ends by escalating for DoD approval — the only mandatory human gate before autonomous execution.
_Avoid_: Setup, init, onboarding

**Verification Class**:
Declared on every Definition of Done criterion: `machine` if a command's output or a named file proves it, `human` if a person must look at the running software. Business logic, behaviour and flow, and "builds and starts without crashing" are machine; appearance, contrast, and whether a control can be seen and found are human. A user-facing capability usually needs one of each — asserting only the machine half is how a correctly-wired control ships invisible. A DoD with user-facing behaviour and no human criteria is a defect.
_Avoid_: Test type, manual test (the distinction is who can judge it, not how it is executed)

**Human Verification Request**:
The checklist the Verifier queues when every machine criterion holds but human ones are unsigned. One numbered row per criterion, each naming what to open, what to do and what to expect, written so a person can act on it without reading code. It blocks `DONE` — not any task — so the loop still runs to exhaustion first and asks once, at the end.
_Avoid_: Manual QA, sign-off request (understates that it is a gate)

**Definition of Done**:
The testable acceptance criteria derived from the PRD and approved by the human. The only human-owned artifact inside `.harness/run/` (`DoD.md`); immutable after approval — the engine may propose changes but never apply them.
_Avoid_: Acceptance criteria file, goal, DoD checklist

**Plan**:
The machine-owned execution strategy (`PLAN.md`, `TASKS/`). Fully owned by the engine; evolves through Tier 1 and Tier 2 mutations. The human never approves the plan — only the Definition of Done.
_Avoid_: Roadmap, backlog

**Reconcile**:
The per-iteration step that classifies every discovery (build failure, hidden dependency, ambiguity…) into no action, task amendment, retry, or escalation. Planning lives here, not in a separate phase.
_Avoid_: Re-plan, replanning phase

**Tiered Mutability**:
The rule set governing who may change what: Tier 1 = engine amends tasks freely (logged), Tier 2 = engine stops and proposes plan/architecture restructuring, Tier 3 = intent (PRD) changes, human-only.

**Fresh-Context Review**:
Per-task review performed by a clean-context subagent that receives only the diff, the task description, the Definition of Done, project standards, and evidence (build/test output) — never the implementation reasoning, because that reasoning may contain the original mistake. Findings flow into Reconcile.
_Avoid_: Self-review, code review (generic)

**DONE-Candidate**:
The state recorded when the engine believes the Goal is complete. The iteration that completed the last task may never emit DONE; the next, fresh iteration re-verifies every DoD criterion against evidence and alone may emit DONE. The builder creates, the reviewer challenges, the verifier confirms.
_Avoid_: Done, complete (before fresh verification)

**Constraint**:
An entry in `knowledge/` recording a trap — "never X here, because Y", with the evidence it came from. Distinguished from Reference by one question: if a Worker ignored it, would the result be *wrong* rather than untidy? Constraints are carried verbatim into every Worker Brief, never filtered by the dispatching Iteration, and the Fresh-Context Review treats a violation as blocking. They outrank a literal reading of an acceptance criterion. This is the mechanism by which a lesson learned in one run binds every Worker in every later run.
_Avoid_: Rule, guideline, convention (a convention is Reference — breaking it is untidy, not wrong)

**Knowledge**:
The engine-maintained cache of verified operational truth about a consumer repository — build/test/lint commands, conventions, environmental quirks learned through execution. Lives in `.harness/knowledge/` at the consumer root; survives every feature run; human-editable without approval gates. It is a cache, never the source of truth: on conflict, the codebase wins and the engine corrects the cache.
_Avoid_: Docs, memory, wiki

**Roll-up Summary**:
The Skill's end-of-run report, produced when a run reaches `DONE`: every Loop Branch in the repository — not only the one that just finished — with its status (done / in-progress / stuck on an unanswered escalation / stale), what it contains, and whether it is merge-ready. A repository can accumulate more than one Loop Branch across separate PRDs over time; the summary exists so the human always sees the full picture, not just the latest run.
_Avoid_: Report, digest, changelog

**Consumer repository**:
Any repository that installs the loop — either via the Skill (`npx skills@latest add`, then `/loop-runtime`) or by copying `.harness/loop/` directly — and provides a Goal. The Loop Runtime never knows the consumer's tech stack.
_Avoid_: Host project, target repo
