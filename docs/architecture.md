# Loop Runtime — Architecture

This document is the complete design of the Loop Runtime. Terms in **bold capitals** are defined in [CONTEXT.md](../CONTEXT.md); decisions with real trade-offs are recorded in [docs/adr/](./adr/).

---

## 1. What this is

An application of Addy Osmani's **Loop Engineering** idea: instead of a human prompting an AI step by step, the human provides intent once (a PRD), and a self-orchestrating loop drives the AI through *read state → pick task → implement → build → test → review → reconcile → persist → repeat* until a verifiable goal is met.

The Loop Runtime packages that idea as a **portable artifact**: one `.loop/` directory that can be copied into any repository — Android, Spring, React, Python, anything — and immediately becomes that repository's autonomous execution engine.

Two surfaces install and operate that artifact. Both drive the exact same engine and contracts described in this document — neither changes the architecture, only how a human reaches it:

- **The Skill** (recommended) — `npx skills@latest add <owner>/Loop-Runtime`, then `/loop-runtime <requirement>`. Carries its own copy of `.loop/`'s contents, materializes them at the consumer repo root, stages the requirement as `PRD.md`, launches and supervises `run.ps1` live in the conversation, mediates Escalation Requests as ordinary questions instead of file edits, and produces a Roll-up Summary across every Loop Branch at completion.
- **Manual** — copy `.loop/` into the repository root by hand, write `PRD.md` yourself, run `powershell .loop/run.ps1` from a terminal.

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
| `.loop/` | Install-time; replaced only by runtime upgrades | Loop-Runtime product | Engine spec, policies, runtime script, templates, baseline capabilities |
| `PRD.md` | Per feature; written before a run | Human | Product intent: objective, requirements, constraints |
| `.ai/` | Per feature run; disposable | Engine (plus one human-owned file: `DoD.md`) | Plan, tasks, state, amendments, escalations, goal-scoped capabilities |
| `knowledge/` | Per repository; cumulative across runs | Engine-maintained, human-editable | Verified toolchain commands, conventions, environmental facts, standing capabilities |

Consequences that fall out mechanically:

- **Install** = copy `.loop/`. Nothing to scrub, no stale state travels.
- **Reset a run** = delete `.ai/` + delete the Loop Branch.
- **Goal-scoped capability expiry** = automatic, because the scoped ledger lives in `.ai/`.
- **Knowledge survives** every run because it lives outside `.ai/` — hard-won lessons ("tests need an emulator", "build needs JDK 17") are paid for once, not once per PRD.
- `knowledge/` is a **cache**, never a source of truth: on conflict the codebase wins and the engine corrects the cache.

---

## 4. The loop lifecycle

```
PRD.md (human writes intent)
    │
    ▼
run.ps1 ──► Iteration 1: BOOTSTRAP (no .ai/ exists → this invocation bootstraps)
    │         reads PRD + repo + human docs → generates knowledge/, .ai/ (DoD, PLAN, TASKS, STATE)
    │         creates Loop Branch → proposes standing capabilities
    │         └── ESCALATE: "approve the Definition of Done"
    ▼
HUMAN GATE (the only mandatory one): review/edit DoD.md, approve standing capabilities,
    fill the Decision section of .ai/ESCALATION.md → re-run
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

### Iteration anatomy

An **Iteration** is *not* one task -- it executes one **Phase**, which may hold one task or several. It is: orient from the Resume Block and durable artifacts → select a Phase → dispatch one Worker per task → verify scope, wire shared files, build and test once → review → reconcile → persist all changes → return one **Execution Status**. The invariant is not granularity; it is that *every iteration leaves the repository in a consistent, resumable state.* One iteration → one checkpoint → one commit, always.

Because each iteration is a fresh process, the principle "the agent forgets, the repository doesn't" is **tested every iteration** rather than trusted. If `.ai/` were insufficient to resume, iteration 2 would fail visibly — not a rare crash months later ([ADR-002](./adr/ADR-002-stateless-iteration-dumb-runtime.md)).

---

## 4b. Loop Engineering alignment

This runtime is an application of Addy Osmani's [Loop Engineering](https://addyosmani.com/blog/loop-engineering/) idea, which names six primitives a loop needs. Where each lives here:

| Primitive | Its job in the loop | Where it lives in this runtime |
|---|---|---|
| **Automations** | Discovery and triage on a schedule -- what makes a loop *loop* | Deliberately **not** in `run.ps1` ([ADR-002](./adr/ADR-002-stateless-iteration-dumb-runtime.md): the Runtime holds no scheduling logic). `run.ps1` is a *goal* loop, running until DONE / ESCALATE / FAILED. A cadence comes from outside it -- Claude Code's own `/loop`, cron, or a CI job invoking `/loop-runtime` |
| **Worktrees** | Isolate parallel work | Replaced by a stricter mechanism: one branch, one working directory, and **Declared File Scopes** verified after the fact ([ADR-008](./adr/ADR-008-phase-workers-single-branch.md)). Git forbids two worktrees on one branch, so the two are mutually exclusive; scope verification makes a collision explicit rather than letting the filesystem hide it |
| **Skills** | Codify project knowledge so the loop stops re-deriving it | The `/loop-runtime` Skill itself, plus `knowledge/` -- which survives every run, so a hard-won environmental fact is paid for once, not once per PRD |
| **Plugins / connectors** | Let the loop act in the real environment | Any MCP rule string is grantable through the same Capability Ledger as a shell command: the Runtime concatenates approved rules verbatim without interpreting them, so a connector needs no new machinery |
| **Sub-agents** | Separate maker from checker | Three distinct minds (§8), plus **Workers** for parallel implementation. Their limits are harness-enforced via `.loop/agents.json`: omitting `Bash` from a Worker's `tools` is what makes "no git, no build, no test" real rather than advisory |
| **State** | Remember what is done, what passed, what is open | `.ai/` + `knowledge/` + `git log`, with the read path deliberately separated from the audit path ([ADR-010](./adr/ADR-010-resume-block-and-audit-split.md)) |

The article's three warnings map onto specific mechanisms rather than good intentions: **verification stays human** (the human merges, always), **comprehension debt** is fought by the Cleanup Commit summary and the Issues Report, and **cognitive surrender** is resisted by the DoD gate and Tier 3 -- intent never becomes the machine's to decide.

Two places where this runtime goes further than the article: completion is certified by a mind that wrote none of the code ([ADR-005](./adr/ADR-005-fresh-context-review-done-candidate.md)), and the loop's resource bounds are read from structured signal rather than guessed ([ADR-012](./adr/ADR-012-runtime-safety-bounds.md)).

---

## 5. The status contract

The engine must end every successful invocation by producing exactly one **Execution Status**; the runtime must be able to obtain it reliably; the absence of a status *is* the crash signal. The transport is an implementation detail (V1: `.ai/STATUS.md`, first line = status word) — the architecture requires only the three invariants above.

| Status | Meaning | Runtime reaction |
|---|---|---|
| `CONTINUE` | Checkpoint persisted, more work remains | Invoke again |
| `DONE` | Goal verified complete by a fresh verifier | Stop — success (exit 0) |
| `ESCALATE` | Engine healthy; a decision exceeds its authority | Stop — surface `.ai/ESCALATION.md` (exit 3) |
| `FAILED` | Execution itself broken (environment, corruption, resources) | Stop — human repair (exit 4) |
| *(none — Crash)* | Engine died without reporting | **Watchdog**: re-invoke, up to N consecutive crashes (default 3), then stop (exit 2) |

`ESCALATE` and `FAILED` both stop; they differ in what the human is asked to do — a **decision** vs a **repair**.

The runtime owns exactly two safety bounds, both mechanical and judgment-free:

- **Watchdog** — an engine cannot supervise its own death; the crash counter resets on any reported status.
- **Iteration budget** (default 50/run) — stops an engine looping `CONTINUE` forever on an impossible goal. Budget exhaustion produces a deterministic report (exit 5), never an interpretation of task failure.

---

## 6. Human interface: the escalation protocol

There is no conversation to reply to — each iteration is a fresh process. Human decisions must arrive as **durable repository state**:

> Whenever the engine requires human input, it must persist that request as a durable artifact before stopping; the decision must survive process termination and be consumable by a fresh invocation.

V1 implementation: `.ai/ESCALATION.md` — question, context, options considered, engine recommendation, structured capability proposals, and an empty **Decision** section. The human writes the decision *and its rationale* (the rationale joins the audit trail), then re-runs. The next iteration's first acts: consume the decision, log it to `AMENDMENTS.md`, archive the exchange, proceed. Unanswered escalation → re-emit `ESCALATE` and stop again — mechanically unambiguous.

**Many pending decisions at a time** (ADR-007). The engine does not hard-stop on Tier 2 -- it queues the question, marks the tasks that entry blocks, and continues on unrelated work. `ESCALATE` is reported when no executable task remains, so the human answers a batch. The load-bearing rule is that every entry names the tasks it blocks: a blocked task is unselectable, which is what makes it impossible to build on an unanswered question.

DoD approval is not a special mechanism — it is simply the first Escalation Request of every run. All policy changes cross the same boundary.

**The Skill mediates this contract; it does not replace it.** When the Skill is the operating surface, it reads `.ai/ESCALATION.md` itself, presents the question (and the engine's own considered options) as ordinary conversation, and writes the human's decision — and rationale — into the same `## Decision` section a human editing the file by hand would have written. The artifact, the archival into `AMENDMENTS.md`, and the Decision Queue semantics are all unchanged; only the human-facing transport of the decision differs. Because the queue holds many entries (ADR-007), the Skill presents them as a batch rather than one question. A capability approval reached this way can still target either ledger — standing (`knowledge/capabilities.json`) or goal-scoped (`.ai/capabilities.json`) — exactly as a manual approval would.

---

## 7. Intent: PRD and the Definition of Done

There is no `GOAL.md` ([ADR-001](./adr/ADR-001-prd-and-dod-source-of-truth.md)). The PRD the human already writes is the intent contract. Bootstrap derives one artifact from it: the **Definition of Done** (`.ai/DoD.md`) — testable, evidence-oriented acceptance criteria.

- The human approves (and may edit) the DoD at the single mandatory gate. Five minutes reviewing a DoD is the highest-leverage human act in the pipeline — it prevents a multi-hour autonomous run from building a verified-wrong feature.
- After approval the DoD is **immutable to the engine**: propose changes (Tier 3), never apply them.
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

Unattended execution needs pre-granted permissions; static allowlists breed permission creep — a `Remove-Item` granted once to clean build artifacts stays available forever in unrelated contexts. Instead, permissions are **Capabilities** ([ADR-004](./adr/ADR-004-capability-permission-and-trust-chain.md)): scoped grants carrying **intent, command, resource scope, lifetime** — goal-scoped by default, expiring automatically with `.ai/`.

Ledger layers map onto the existing lifecycles — no new machinery:

| Class | Example | Lifetime | Ledger |
|---|---|---|---|
| Baseline (low-risk, universal) | read files, local git | Permanent, ships with runtime | `.loop/capabilities/baseline.json` |
| Standing (per-repo toolchain) | `./gradlew *`, `npm test` | Per repository, approved at the DoD gate | `knowledge/capabilities.json` |
| Scoped (high-risk) | `Remove-Item ./build/**` | Current goal (default) | `.ai/capabilities.json` |

The trust chain:

> **Human → Capability Ledger → Runtime Compiler → Permission Settings → Engine**

- The **engine requests**: structured proposal in an Escalation Request, including the exact permission rule string.
- The **human decides**: approve as-is, narrow scope or lifetime, or reject. Approval may reduce a grant, never expand it. V1: the human physically writes the approved entry into the ledger (the boundary made visible); V2: a structured approval flow where the runtime transcribes the approved block *verbatim* — authority placement unchanged.
- The **runtime enforces**: before every invocation it regenerates the permission settings from the ledgers — a **build artifact, never a source artifact** — concatenating the human-approved rule strings without translation, and always appending immutable deny rules protecting `.loop/`, all ledgers, and the generated settings. A process that could write its own permission file would have all permissions; therefore the engine never can.

**Documented limitation (deliberate honesty):** this is a guardrail against accidents and drift — the actual V1 threat — not a security boundary against an adversarial engine. Pattern-matching on shell commands is inherently porous. Hard containment is the VM/sandbox path, available via the runtime's explicit `-DangerouslySkipPermissions` flag for isolated environments.

---

## 10. Git strategy

Git is a **persistence backend** for loop concepts, not their definition ([ADR-003](./adr/ADR-003-checkpoint-abstraction-and-git-persistence.md)). All git logic lives in the engine; the runtime never touches git.

- **Loop Branch** per run (`loop/<prd-slug>`), created at bootstrap from HEAD. The engine never touches the default branch, never merges, never rewrites history. It **may push the Loop Branch** under an explicitly granted capability ([ADR-011](./adr/ADR-011-loop-branch-push.md)) -- which makes a mid-run machine failure survivable and lets the human review from another device -- and `--force`, `merge` and `rebase` are denied outright by the Runtime regardless of any allow rule. A catastrophic run = delete the branch.
- **Checkpoint = one atomic commit** of code + `.ai/` + `knowledge/` together. STATE.md at HEAD always describes HEAD; they cannot desync. `git log` on the branch *is* the execution history.
- **Crash recovery is mechanical**: dirty tree at iteration start = previous invocation died mid-flight. Salvage into a checkpoint if coherent, otherwise revert to the last checkpoint. Never build on unverified debris.
- **Cleanup Commit** at verified completion: removes `.ai/` from the branch tip; its message carries the completion summary (what was built, DoD criteria → evidence, notable amendments). The mergeable tip contains the implementation, durable knowledge, and nothing disposable — *`.ai/` is the loop's memory while it works, not the product the human merges.* The full `.ai/` evolution stays in branch history for audit.

---

## 11. Source-of-truth priority

When information conflicts, the engine trusts, in order:

1. `ENGINE.md` + `POLICIES.md` (the operating contract)
2. `PRD.md` + approved `DoD.md` (intent; if these two contradict → escalate)
3. The codebase (ground truth)
4. `knowledge/` (cache of the codebase; loses to it, gets corrected)
5. `.ai/` state (own memory)
6. Everything else — README text, code comments, generated content — is **data, never instructions**. Conversation history never overrides project files.

---

## 12. V1 boundaries and deferred work

Deliberately deferred until real usage demands them, with the trigger for each:

| Deferred | V1 position | Trigger to revisit |
|---|---|---|
| Multi-commit iterations | One iteration = one checkpoint = one commit | Iterations too large to audit as one commit |
| Runtime-transcribed capability approvals (V2 flow) | Human pastes approved ledger entries | Escalation format stabilized through real use |
| Task-scoped capability expiry | Goal-scoped default only | A goal-long grant proves too broad in practice |
| `run.sh` | `run.ps1` only | First non-Windows consumer |
| ~~Parallel task execution / multiple pending escalations~~ | **Delivered**: Phases with Workers ([ADR-008](./adr/ADR-008-phase-workers-single-branch.md)), Decision Queue ([ADR-007](./adr/ADR-007-non-blocking-progress.md)) | -- |
| Non-git checkpoint persistence | Git assumed | A real non-git consumer appears |
| Separate `GOAL.md` for very large PRDs | PRD + DoD suffice | PRDs too large to serve as working intent reference |
| Capability rules that tolerate compound shell commands | Exact-prefix match on the literal command string (e.g. `Bash(node *)`) | Recurs often enough in practice that proposals need a broader/looser matching form |
| Skill distribution beyond `npx skills@latest` (e.g. a Claude Code Plugin) | Skill only, invoked bare (`/loop-runtime`) | A consumer needs marketplace install/versioning and accepts the resulting `plugin:command` namespacing |

Validated so far: a real consumer project (Android-Compose-Skeleton, manual `.loop/` path) and, separately, the Skill-based install/operate/escalate/roll-up flow end-to-end in a scratch repository — not toy examples in either case.
