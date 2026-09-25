# Foreman — Architecture

This document is the complete design of Foreman. Terms in **bold capitals** are defined in [CONTEXT.md](../CONTEXT.md); decisions with real trade-offs are recorded in [docs/adr/](./adr/).

---

## 1. What this is

An application of Addy Osmani's **Loop Engineering** idea: instead of a human prompting an AI step by step, the human provides intent once (a PRD), and a self-orchestrating loop drives the AI through *read state → pick task → implement → build → test → review → reconcile → persist → repeat* until a verifiable goal is met.

Foreman packages that idea as a **portable artifact**: one `.harness/loop/` directory that can be copied into any repository — Android, Spring, React, Python, anything — and immediately becomes that repository's autonomous execution engine.

Two surfaces install and operate that artifact. Both drive the exact same engine and contracts described in this document — neither changes the architecture, only how a human reaches it:

- **The Skill** (recommended) — `npx skills@latest add <owner>/Foreman`, then `/foreman <requirement>`. Carries its own copy of `.harness/loop/`'s contents, materializes them at the consumer repo root, stages the requirement as `PRD.md`, launches and supervises `run.ps1` live in the conversation, mediates Escalation Requests as ordinary questions instead of file edits, and produces a Roll-up Summary across every Loop Branch at completion.
- **Manual** — copy `.harness/loop/` into the repository root by hand, write `PRD.md` yourself, run `powershell .harness/loop/run.ps1` from a terminal.

The Skill is additive: it stages input and supervises/summarizes output, but exercises no authority the Trust Chain (§9) didn't already grant through a human-approved Capability. Everything from §2 onward describes the engine and runtime both surfaces drive identically.

The objective is not autonomous coding for its own sake. It is an execution system that is **safe, predictable, auditable, resumable, and human-governed**, where the human's involvement concentrates at the two points of highest leverage: defining intent before the code, and reviewing the deliverable after it.

---

## 2. The three planes

The architecture separates authority into three planes, applied uniformly to work, plans, and permissions:

> **The engine requests. The human decides. The runtime enforces.**

| Plane | Component | Nature | May never |
|---|---|---|---|
| Judgment | **Execution Engine** (one Claude Code invocation governed by `ENGINE.md`) | Intelligent | Expand its own authority, alter intent, declare its own work complete |
| Authority | **Human** | Decisive | Be bypassed for policy changes (intent, architecture, capabilities) |
| Enforcement | **Runtime** (`run.ps1`) | Mechanical, deterministic | Make engineering decisions or interpret intent |

The governing invariant, preserved across every mechanism below:

> The runtime enforces contracts but never makes engineering decisions. The engine performs work but never expands its own authority. Human approval remains the only boundary for policy changes.

---

## 3. The four artifacts and their lifecycles

A consumer repository contains four loop artifacts. There are four **because there are four lifecycles** — artifacts with different lifecycles never share a folder whose primary operation (copy, delete) is folder-level:

| Artifact | Lifecycle | Owner | Content |
|---|---|---|---|
| `.harness/loop/` | Install-time; replaced only by runtime upgrades | Foreman product | Engine spec, policies, runtime script, templates, baseline capabilities |
| `PRD.md` | Per feature; written before a run | Human | Product intent: objective, requirements, constraints |
| `.harness/run/` | Per feature run; disposable | Engine (plus one human-owned file: `DoD.md`) | Plan, tasks, state, amendments, escalations, goal-scoped capabilities |
| `.harness/knowledge/` | Per repository; cumulative across runs | Split — see below | `PROJECT.md`, optional `DOMAIN.md`, standing capabilities |

`.harness/knowledge/` holds two files with different owners and incompatible rules ([ADR-019](./adr/ADR-019-knowledge-stratification-and-ratchet.md)):

| File | Owner | Content | How an entry is treated |
|---|---|---|---|
| `PROJECT.md` | Engine (human-editable, no gate) | Verified toolchain commands, conventions, environmental facts — split internally into **Constraints** and **Reference** | **Reference: conform to it. Constraint: avoid what it names.** On conflict the codebase wins — it caches facts about the code, so the code corrects it |
| `DOMAIN.md` (optional) | **Human only**; engine-immutable via deny rules | Domain rules, formulas, algorithms, business and regulatory invariants | **Implement it exactly.** On conflict `DOMAIN.md` wins — the code is an *attempt* at the rule, so a difference is a defect in the code |

The Constraint/Reference split inside `PROJECT.md` ([ADR-016](./adr/ADR-016-constraints-are-never-filtered.md)) exists because "how it is" and "what is wrong with it" cannot be treated alike: a defect recorded as a fact is read as the local convention and reproduced on purpose. A Constraint is carried verbatim into every Worker Brief and never filtered, so it reaches the Worker before code is written; a known defect is therefore always a Constraint, phrased as an instruction rather than an observation ([ADR-018](./adr/ADR-018-constraints-retire-the-open-issues-file.md), which retired the separate `ISSUES.md` that ADR-008 had introduced).

Neither is a home for knowledge about a technology stack in general (platform API behaviour, framework idioms): that is not truth about *this* repository, nothing here can verify it, and it rots with no mechanism to correct it. Stack knowledge belongs in a separate opt-in, human-curated pack — never auto-promoted into `.harness/loop/`.

Consequences that fall out mechanically:

- **Install** = copy `.harness/loop/`. Nothing to scrub, no stale state travels.
- **Reset a run** = delete `.harness/run/` + delete the Loop Branch.
- **Goal-scoped capability expiry** = automatic, because the scoped ledger lives in `.harness/run/`.
- **Knowledge survives** every run because it lives outside `.harness/run/` — hard-won lessons ("tests need an emulator", "build needs JDK 17") are paid for once, not once per PRD.
- `.harness/knowledge/` is a **cache**, never a source of truth: on conflict the codebase wins and the engine corrects the cache.

---

## 4. The loop lifecycle

```
PRD.md (human writes intent)
    │
    ▼
run.ps1 ──► Iteration 1: BOOTSTRAP (no .harness/run/ exists → this invocation bootstraps)
    │         reads PRD + repo + human docs → generates knowledge/, .harness/run/ (DoD, PLAN, TASKS, STATE)
    │         creates Loop Branch → proposes standing capabilities
    │         └── ESCALATE: "approve the Definition of Done"
    ▼
HUMAN GATE (the only mandatory one): review/edit DoD.md, approve standing capabilities,
    write the decision into .harness/run/DECISIONS.md (never into ESCALATION.md) → re-run
    ▼
run.ps1 ──► Iterations 2..N: EXECUTE
    │         each: recover → consume decisions → orient → select task → implement
    │               → build → test → fresh-context review → reconcile → persist
    │               → one atomic checkpoint commit → one Execution Status
    │         CONTINUE → invoke again        ESCALATE/FAILED → stop for the human
    ▼
DONE-candidate recorded (engine believes goal complete — may NOT say DONE itself)
    ▼
run.ps1 ──► Final iteration: FRESH VERIFICATION
    │         a fresh invocation that wrote none of the code re-proves every DoD criterion
    │         gaps → file tasks, CONTINUE           all hold → Cleanup Commit → DONE
    ▼
HUMAN: reviews the Loop Branch (tip = implementation + knowledge + completion summary,
    no execution state) and merges. Merging is always a human act.
```

At that fresh-verification step a criterion belongs to one of three classes
([ADR-030](./adr/ADR-030-a-machine-drives-a-human-criterion-before-a-person-signs-it.md)): `machine`,
closed by a command; `machine-then-human`, **driven** by the verifier on an emulator or device and
then signed by a person; and `human-only`, perception that nothing may claim. A machine never closes
a criterion a person owns — it exists so that the person is not the first to find the defect. The
criteria still awaiting a signature survive the run that raised them, in `knowledge/ISSUES.md`.


### Iteration anatomy

An **Iteration** is *not* one task. It is: reconstruct context from durable artifacts → execute autonomously until a **Stable Checkpoint** → persist all changes → return one **Execution Status**. The invariant is not granularity; it is that *every iteration leaves the repository in a consistent, resumable state.* For V1 simplicity: one iteration → one checkpoint → one commit.

Because each iteration is a fresh process, the principle "the agent forgets, the repository doesn't" is **tested every iteration** rather than trusted. If `.harness/run/` were insufficient to resume, iteration 2 would fail visibly — not a rare crash months later ([ADR-002](./adr/ADR-002-stateless-iteration-dumb-runtime.md)).

---

## 5. The status contract

The engine must end every successful invocation by producing exactly one **Execution Status**; the runtime must be able to obtain it reliably; the absence of a status *is* the crash signal. The transport is an implementation detail (V1: `.harness/run/STATUS.md`, first line = status word) — the architecture requires only the three invariants above.

| Status | Meaning | Runtime reaction |
|---|---|---|
| `CONTINUE` | Checkpoint persisted, more work remains | Invoke again |
| `DONE` | Goal verified complete by a fresh verifier | Stop — success (exit 0) |
| `ESCALATE` | Engine healthy; a decision exceeds its authority | Stop — surface `.harness/run/ESCALATION.md` for the question, `.harness/run/DECISIONS.md` for the answer (exit 3) |
| `FAILED` | Execution itself broken (environment, corruption, resources) | Stop — human repair (exit 4) |
| `DONE_PARTIAL` | Autonomous mode only: no work left, verified as far as it goes, but an abandoned task, unsigned `human` criterion or Tier-3 Assumption stops `DONE` | Stop — render the Run Report (exit 7) |
| *(none — Crash)* | Engine died without reporting | **Watchdog**: re-invoke, up to N consecutive crashes (default 3), then stop (exit 2). Autonomous mode keeps re-invoking with exponential backoff instead |

`ESCALATE` and `FAILED` both stop; they differ in what the human is asked to do — a **decision** vs a **repair**.

The runtime owns exactly two safety bounds, both mechanical and judgment-free:

- **Watchdog** — an engine cannot supervise its own death; the crash counter resets on any reported status.
- **Iteration budget** (default 50/run, plus an optional `-MaxHours` wall-clock bound) — stops an engine looping `CONTINUE` forever on an impossible goal. Budget exhaustion produces a deterministic report (exit 5), never an interpretation of task failure. Counted from commits already on the Loop Branch, not a process-local variable, so it survives a restart across `ESCALATE`, a Crash-limit, or a quota wait ([ADR-024](./adr/ADR-024-the-iteration-budget-is-counted-from-commits-not-a-process-variable.md)).

---

## 6. Human interface: the escalation protocol

There is no conversation to reply to — each iteration is a fresh process. Human decisions must arrive as **durable repository state**:

> Whenever the engine requires human input, it must persist that request as a durable artifact before stopping; the decision must survive process termination and be consumable by a fresh invocation.

V1 implementation, in **two files with one writer each** ([ADR-025](./adr/ADR-025-the-decision-queue-splits-into-an-engine-owned-and-a-human-owned-file.md)): `.harness/run/ESCALATION.md` — question, context, options considered, engine recommendation, structured capability proposals — is the engine's own log. `.harness/run/DECISIONS.md` — where the human writes the decision *and its rationale* (the rationale joins the audit trail) — is deny-listed against the engine, mechanically, the same as a Capability Ledger. A human should wait for the run to actually stop (`Status: ESCALATE`) before answering, never for `ESCALATION.md` merely appearing on disk — queuing a decision does not stop the run, so the engine may still be working, and writing to that file itself, well after it is written. The next iteration's first acts: consume any answered id from `DECISIONS.md`, log it to `AMENDMENTS.md`, archive the exchange, proceed. Unanswered escalation → re-emit `ESCALATE` and stop again — mechanically unambiguous.

Escalation Requests **queue**: the engine marks the tasks a question blocks, keeps working on everything else, and stops only when no unblocked work remains ([ADR-007](./adr/ADR-007-non-blocking-progress.md)), so one stop can carry several questions. (Earlier versions of this page said "at most one pending escalation at a time"; that described the V1 hard stop, which ADR-007 replaced.)

DoD approval is not a special mechanism — it is simply the first Escalation Request of every run. All policy changes cross the same boundary.

**Autonomous mode keeps only that first one** ([ADR-027](./adr/ADR-027-a-run-chooses-collaborative-or-autonomous-mode-at-launch.md)). The human chooses the **Run Mode** at launch and may switch it mid-run; it lives in `.git/foreman-mode`, outside the working tree and deny-listed against the engine. In Autonomous mode every later Tier-2 or Tier-3 question becomes a recorded **Assumption** in `.harness/run/ASSUMPTIONS.md` instead of an Escalation Request, `human` criteria are reported in `ISSUES.md` instead of queued, and the run ends `DONE` or `DONE_PARTIAL` with a Run Report the Runtime renders. A human Decision still outranks any Assumption.

**The Skill mediates this contract; it does not replace it.** When the Skill is the operating surface, it reads `.harness/run/ESCALATION.md` itself, presents the question (and the engine's own considered options) as ordinary conversation, and writes the human's decision — and rationale — into `.harness/run/DECISIONS.md` under the entry's id, exactly where a human editing by hand would. The artifact and the archival into `AMENDMENTS.md` are unchanged; only the human-facing transport of the decision differs. A capability approval reached this way can still target either ledger — standing (`.harness/knowledge/capabilities.json`) or goal-scoped (`.harness/run/capabilities.json`) — exactly as a manual approval would.

---

## 7. Intent: PRD and the Definition of Done

There is no `GOAL.md` ([ADR-001](./adr/ADR-001-prd-and-dod-source-of-truth.md)). The PRD the human already writes is the intent contract. Bootstrap derives one artifact from it: the **Definition of Done** (`.harness/run/DoD.md`) — testable, evidence-oriented acceptance criteria.

- The human approves (and may edit) the DoD at the single mandatory gate. Five minutes reviewing a DoD is the highest-leverage human act in the pipeline — it prevents a multi-hour autonomous run from building a verified-wrong feature.
- After approval the DoD is **immutable to the engine**: propose changes (Tier 3), never apply them.
- The DoD also names **what the PRD makes unnecessary** — its **Removals**: screens, permissions, services, dependencies and demo data the repository already ships, each as a `machine` criterion stating absence [ADR-028](./adr/ADR-028-the-definition-of-done-names-what-the-prd-makes-unnecessary.md). Bootstrap first classifies the repository as a *template* (propose removing every unused demo feature) or a *product* (remove only what the PRD replaces or leaves unreachable; ask about the rest). The human approves deletions at the same gate, so whether existing code stays is intent, never an engine judgement.
- The **Plan** is deliberately *not* approved: execution strategy belongs to the engine. Human owns *what done means*; engine owns *how to get there*.

### Tiered Mutability

| Tier | What | Who | Mechanism |
|---|---|---|---|
| 1 | Split/merge/reorder tasks, prerequisites, obsolete removal | Engine, automatic | Logged in `AMENDMENTS.md` (timestamp, tier, reason, affected tasks, decision, impact); execution continues |
| 2 | Architecture, execution strategy, large restructuring, capability grants | Engine proposes, human approves | Hard stop: Escalation Request → `ESCALATE`. No speculative execution past the boundary |
| 3 | PRD / approved DoD — intent itself | Human only | Engine may only propose. Forever |

---

## 8. Verification: builder, reviewer, verifier

Three distinct minds, because the dominant failure mode is *shared misunderstanding* — the context that introduced a wrong assumption is the least likely to detect it ([ADR-005](./adr/ADR-005-fresh-context-review-done-candidate.md)):

1. **Builder** — the iteration's main context: implements, builds, tests.
2. **Reviewer** — a **Fresh-Context Review** subagent per task: clean context, receives only the diff, task description, DoD, standards, and evidence — never the implementation reasoning. Findings flow into Reconcile.
3. **Verifier** — the **DONE-Candidate** rule: the iteration completing the last task may never emit `DONE`. It records DONE-candidate and reports `CONTINUE`. The next fresh invocation — which wrote none of the code — re-proves every DoD criterion against evidence and alone may emit `DONE`.

Completion is a claim; the certification of that claim never shares a mind with its creation.

**Reconcile** runs every iteration ("what did I learn?"): each discovery classifies into *no action / task amendment (Tier 1) / knowledge update / retry (only if success probability increased) / escalation*. Planning is not a separate loop phase — it happens continuously inside Reconcile.

---

## 9. Permissions: the capability model

Unattended execution needs pre-granted permissions; static allowlists breed permission creep — a `Remove-Item` granted once to clean build artifacts stays available forever in unrelated contexts. Instead, permissions are **Capabilities** ([ADR-004](./adr/ADR-004-capability-permission-and-trust-chain.md)): scoped grants carrying **intent, command, resource scope, lifetime** — goal-scoped by default, expiring automatically with `.harness/run/`.

Ledger layers map onto the existing lifecycles — no new machinery:

| Class | Example | Lifetime | Ledger |
|---|---|---|---|
| Baseline (low-risk, universal) | read files, local git | Permanent, ships with runtime | `.harness/loop/capabilities/baseline.json` |
| Standing (per-repo toolchain) | `./gradlew *`, `npm test` | Per repository, approved at the DoD gate | `.harness/knowledge/capabilities.json` |
| Scoped (high-risk) | `Remove-Item ./build/**` | Current goal (default) | `.harness/run/capabilities.json` |

The trust chain:

> **Human → Capability Ledger → Runtime Compiler → Permission Settings → Engine**

- The **engine requests**: structured proposal in an Escalation Request, including the exact permission rule string.
- The **human decides**: approve as-is, narrow scope or lifetime, or reject. Approval may reduce a grant, never expand it. V1: the human physically writes the approved entry into the ledger (the boundary made visible); V2: a structured approval flow where the runtime transcribes the approved block *verbatim* — authority placement unchanged.
- The **runtime enforces**: before every invocation it regenerates the permission settings from the ledgers — a **build artifact, never a source artifact** — concatenating the human-approved rule strings without translation, and always appending immutable deny rules protecting `.harness/loop/`, all ledgers, and the generated settings. A process that could write its own permission file would have all permissions; therefore the engine never can.

**Autonomous mode inverts the model** ([ADR-027](./adr/ADR-027-a-run-chooses-collaborative-or-autonomous-mode-at-launch.md)): every tool is allowed, minus a **Deny List** shipped in `baseline.json` and extended per repository, with the immutable deny rules still on top. Destructive actions it may take go through **Recovery Wrappers** in `.harness/loop/bin/` that capture what is lost and record how to restore it in `.harness/run/RECOVERY.md`. The Trust Chain still holds — the human chose the mode and the list — but what the human approves becomes a list of what is refused rather than of what is allowed.

**Documented limitation (deliberate honesty):** this is a guardrail against accidents and drift — the actual V1 threat — not a security boundary against an adversarial engine. Pattern-matching on shell commands is inherently porous. Hard containment is the VM/sandbox path, available via the runtime's explicit `-DangerouslySkipPermissions` flag for isolated environments.

---

## 10. Git strategy

Git is a **persistence backend** for loop concepts, not their definition ([ADR-003](./adr/ADR-003-checkpoint-abstraction-and-git-persistence.md)). All git logic lives in the engine; the runtime never touches git.

- **Loop Branch** per run (`loop/<prd-slug>`), created at bootstrap from HEAD. The engine never touches the default branch, never pushes, never merges, never rewrites history. A catastrophic run = delete the branch.
- **Checkpoint = one atomic commit** of code + `.harness/run/` + `.harness/knowledge/` together. STATE.md at HEAD always describes HEAD; they cannot desync. `git log` on the branch *is* the execution history.
- **Because the branch is the history, `STATE.md` does not have to be.** It is read in full at Orient every iteration, so it keeps only the last three iterations verbatim; older iterations and consumed escalations compact to one-line rows carrying a checkpoint SHA, and the full text is fetched with `git show <sha>:.harness/run/STATE.md` when — and only when — the index is insufficient. Without this, orientation cost grows with run length until it competes with the work; with it, orienting on iteration 40 costs what it did on iteration 4. The compaction is safe only because `Bash(git show*)` is a baseline capability ([ADR-020](./adr/ADR-020-open-issues-survive-the-cleanup-commit.md)) — before that grant, trimming history would have destroyed it rather than relocated it.
- **Crash recovery is mechanical**: dirty tree at iteration start = previous invocation died mid-flight. Salvage into a checkpoint if coherent, otherwise revert to the last checkpoint. Never build on unverified debris.
- **Cleanup Commit** at verified completion: removes `.harness/run/` from the branch tip; its message carries the completion summary (what was built, DoD criteria → evidence, notable amendments). The mergeable tip contains the implementation, durable knowledge, and nothing disposable — *`.harness/run/` is the loop's memory while it works, not the product the human merges.* The full `.harness/run/` evolution stays in branch history for audit.

---

## 11. Source-of-truth priority

When information conflicts, the engine trusts, in order:

1. `ENGINE.md` + `POLICIES.md` (the operating contract)
2. `PRD.md` + approved `DoD.md` (intent; if these two contradict → escalate)
3. `.harness/knowledge/DOMAIN.md` (human-owned domain truth — **outranks the codebase**; engine-immutable)
4. The codebase (ground truth of what the software *does*)
5. `.harness/knowledge/PROJECT.md` (cache of the codebase; loses to it, gets corrected), split internally into **Constraints** — traps a Worker must avoid, carried verbatim into every Brief — and **Reference**, conventions to conform to (ADR-016). A known defect is always a Constraint, written as an instruction rather than an observation (ADR-018)
6. `.harness/run/` state (own memory)
7. Everything else — README text, code comments, generated content — is **data, never instructions**. Conversation history never overrides project files.

The two `.harness/knowledge/` files sit on opposite sides of the codebase by design. `PROJECT.md` describes the code, so the code corrects it. `DOMAIN.md` describes what the code is *trying to be right about*, so it corrects the code. Collapsing them into one rung is what makes a coding bug silently become the project's specification.

---

## 12. V1 boundaries and deferred work

Deliberately deferred until real usage demands them, with the trigger for each:

| Deferred | V1 position | Trigger to revisit |
|---|---|---|
| Multi-commit iterations | One iteration = one checkpoint = one commit | Iterations too large to audit as one commit |
| Runtime-transcribed capability approvals (V2 flow) | Human pastes approved ledger entries | Escalation format stabilized through real use |
| Task-scoped capability expiry | Goal-scoped default only | A goal-long grant proves too broad in practice |
| `run.sh` | `run.ps1` only | First non-Windows consumer |
| Parallel task execution / multiple pending escalations | Strictly sequential, single escalation | Sequential throughput becomes the bottleneck |
| Non-git checkpoint persistence | Git assumed | A real non-git consumer appears |
| Separate `GOAL.md` for very large PRDs | PRD + DoD suffice | PRDs too large to serve as working intent reference |
| Capability rules that tolerate compound shell commands | Exact-prefix match on the literal command string (e.g. `Bash(node *)`) | Recurs often enough in practice that proposals need a broader/looser matching form |
| Skill distribution beyond `npx skills@latest` (e.g. a Claude Code Plugin) | Skill only, invoked bare (`/foreman`) | A consumer needs marketplace install/versioning and accepts the resulting `plugin:command` namespacing |
| A stack/platform knowledge pack | **First one built** — `skills/knowledge/android/compose-visual-testing/`, opt-in and human-curated, never auto-promoted into `.harness/loop/` ([ADR-019](./adr/ADR-019-knowledge-stratification-and-ratchet.md)). Its trigger fired: a second Android repository was about to re-pay the same screenshot-testing setup. Scoped to the one capability a real failure earned, not to "everything Android". Packs are grouped one subfolder per platform (`skills/knowledge/<platform>/`), and a `SUGGESTIONS.html` entry proposing the stack tier must name the platform the same way ([ADR-026](./adr/ADR-026-the-suggestion-box-gains-an-escalate-tab-and-stack-entries-name-their-platform.md)) | A pack accumulates enough unrelated content that it needs splitting by concern, or a second stack needs one |
| `.harness/knowledge/CANDIDATES.md` — staging lessons through the Cleanup Commit for human triage at `DONE` | Not built. `SKILL.md` step 5 already folds vanishing discoveries into the final summary | A lesson is actually lost because nobody was watching the run — the ratchet's own bar, applied to itself |
| Deny-rule protection for `PRD.md` and `.harness/run/DoD.md` | Protocol-protected only, because bootstrap must create `DoD.md` | The ADR-004 V2 transcription flow lands, giving the human-owned artifacts a writer other than the engine |

Validated so far: a real consumer project (Android-Compose-Skeleton, manual `.harness/loop/` path) and, separately, the Skill-based install/operate/escalate/roll-up flow end-to-end in a scratch repository — not toy examples in either case.
