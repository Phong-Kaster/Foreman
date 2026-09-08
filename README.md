# Loop Runtime

A **portable autonomous execution engine** for Claude Code: install one skill, hand it a requirement — inline text or a document path — and a loop of fresh AI iterations plans, implements, builds, tests, reviews, and verifies the feature until it is provably done, stopping for you only at genuine decision points.

An application of Addy Osmani's **Loop Engineering** concept: the human stops being the person who prompts the agent step-by-step and becomes the system designer who owns intent.

> Human owns intent. The loop owns execution.
> The agent forgets. The repository doesn't.
> The engine requests. The human decides. The runtime enforces.

---

## What it is

Loop Runtime is two things working together:

1. **A Claude Code skill** (`/loop-runtime`) — the easy on-ramp. Install it once per repository, then type `/loop-runtime <requirement>` to start or resume a run. The skill materializes the runtime, stages your requirement as `PRD.md`, launches the engine in the background, streams its activity live into your conversation, and turns every decision point into a normal question instead of a file you have to open and edit.
2. **A stateless execution engine underneath** (`.harness/loop/`) — the actual "loop": a thin, dumb PowerShell runtime (`run.ps1`) that repeatedly re-invokes Claude Code headlessly, reading one status word after each invocation (`CONTINUE` / `DONE` / `ESCALATE` / `FAILED`) and reacting mechanically. All the intelligence lives in `ENGINE.md`, the engine's system-prompt specification — never in the runtime itself.

You don't need to think about these as separate things day-to-day — the skill exists specifically so you never have to touch `.harness/loop/` directly.

---

## Install (once per repository)

```
npx skills@latest add Phong-Kaster/Loop-Runtime
```

This installs the `loop-runtime` skill into `.claude/skills/loop-runtime/` (and `.agents/skills/loop-runtime/`) in your current repo, and records it in that repo's `skills-lock.json` — the same mechanism you'd use for any other shared Claude Code skill package. Nothing else needs to be copied by hand.

> Prefer not to use the skill installer? `.harness/loop/` is also a plain, self-contained distributable — copy it into a repo's root and run `powershell .harness/loop/run.ps1` directly from a terminal. See [docs/consumer-guide.md](./docs/consumer-guide.md) for that path. The skill is the recommended way in for anyone already working inside Claude Code.

---

## How to use it

```
/loop-runtime <inline requirement text>
/loop-runtime <path to a requirement document>
/loop-runtime
```

- **Inline text** — e.g. `/loop-runtime add a dark mode toggle to Settings that persists via DataStore` — gets written verbatim into `PRD.md` at your repo root. No rewriting, no summarizing.
- **A document path** — e.g. `/loop-runtime C:\reqs\dark-mode.md` — gets staged as the PRD source instead.
- **No argument** — resumes with whatever `PRD.md` already exists (first run in a repo with no `PRD.md` yet will ask you for one).

From there, the skill:

1. Syncs `.harness/loop/` at your repo root from the installed skill files (so the runtime is always current with whatever version you last installed).
2. Launches `.harness/loop/run.ps1` in the background and attaches a live log stream to the conversation — you watch the engine work the same way you'd watch any other command's output, without it ever tying up your terminal or hitting a foreground timeout.
3. Turns every `ESCALATE` into a real question, right in the chat — the engine's own proposed options become your choices. You never open `.harness/run/ESCALATION.md` yourself; the skill writes your decision into it and resumes automatically.
4. Reports a **roll-up summary across every `loop/*` branch** in the repo when the run reaches `DONE` — not just the one that just finished — so you always see the full picture of what's mergeable, what's still in progress, and what's stuck waiting on a decision.
5. Never merges, pushes, or touches your default branch. That step is always yours.

---

## Worked example

This is a real, verified run — not a hypothetical. `/loop-runtime write a hello world notification` in an empty scratch repo:

**1. Bootstrap runs automatically** (no `.harness/run/` existed yet). The engine reads the PRD, inspects the repo (nothing there, no conventions to infer), confirms Node.js is on `PATH`, creates the branch `loop/hello-world-notification`, and generates `.harness/knowledge/PROJECT.md` plus the full `.harness/run/` scaffold (`DoD.md`, `PLAN.md`, three task files, `STATE.md`).

**2. First stop — a real question, not a file:**

> Approve the Definition of Done? Also: "notification" is ambiguous in the PRD — console-printed output (recommended, zero dependencies) or a real OS-level desktop toast (needs a new capability)? And approve a standing `Bash(node *)` capability for this repo's toolchain?

Answered in chat: console output, approve the capability, approve the DoD as drafted. The skill writes all three into `.harness/run/ESCALATION.md`'s Decision section and relaunches — no file opened by hand.

**3. The loop implements unattended:** `src/notify.js` (prints `"Hello, World!"`, exits 0), `test/notify.test.js` (asserts the greeting via `node:test`), `README.md` updated with run/test instructions. Build and tests both pass. A **fresh-context review sub-agent** — given only the diff, the task, the DoD, and the policies, never the implementation reasoning — flags two non-blocking Minor notes (stdout path not directly asserted; trivial string duplication between source and test) and nothing Critical. One atomic checkpoint commit, `CONTINUE`.

**4. A fresh Verifier iteration** — which wrote none of the code — independently re-runs all five DoD criteria from scratch. All hold. It then hits a genuine capability boundary: removing `.harness/run/` (the required Cleanup Commit) is a destructive git operation it isn't authorized for. Rather than force it, it escalates:

> Final verification passed. May I be granted a one-time, goal-scoped capability to run the Cleanup Commit, or would you rather do that one step manually?

Answered: grant the scoped, one-time capability. It expires the moment `.harness/run/` is removed — no standing deletion capability left behind afterward.

**5. `DONE`.** Roll-up summary:

| Branch | Status | Contains | Merge-ready? |
|---|---|---|---|
| `loop/hello-world-notification` | DONE | `src/notify.js`, `test/notify.test.js`, updated `README.md`, `.harness/knowledge/` cache | Yes — clean tree, `.harness/run/` removed, 6 commits |

Two Minor review notes carried into the summary so they aren't lost when `.harness/run/` disappears. Merging `loop/hello-world-notification` into your default branch is left for you to do by hand.

Total: two escalations, both answered as ordinary conversation; zero files opened; one mergeable branch at the end.

---

## Repository tree

```
Loop-Runtime/
├── skills/engineering/loop-runtime/          ← THE SKILL — what `npx skills@latest add` installs
│   ├── SKILL.md                              ← the skill's own instructions (bootstrap, supervise, escalate, roll-up)
│   ├── ENGINE.md                             ← copy of the Execution Engine Specification
│   ├── POLICIES.md                           ← copy of the engineering policy
│   ├── models.json                           ← copy of the Model Tier Map (ADR-013)
│   ├── agents/                               ← copy of the Worker / Reviewer definitions
│   ├── capabilities/baseline.json            ← copy of the permanent low-risk capability ledger
│   ├── templates/                            ← copy of the run/ + knowledge/ blueprints
│   └── scripts/run.ps1                       ← copy of the runtime script
│
├── .harness/loop/                            ← THE STANDALONE DISTRIBUTABLE — for manual/non-skill installs
│   ├── ENGINE.md                             ← materializes into a consumer's .harness/loop/ verbatim
│   ├── POLICIES.md
│   ├── models.json
│   ├── agents/
│   ├── capabilities/baseline.json
│   ├── templates/
│   └── run.ps1
│
├── tests/                                    ← Pester unit tests for run.ps1's own mechanics
│   ├── run.Tests.ps1                         ← status reactions, PRD staging, prerequisites, via a fake-claude stub
│   └── fixtures/fake-claude.ps1              ← stands in for the real `claude` CLI — no API calls, no cost
│
├── docs/
│   ├── adr/                                  ← decision records (semantic filenames — self-explanatory)
│   ├── architecture.md                       ← the complete design: planes, lifecycles, loop, contracts
│   └── consumer-guide.md                     ← manual-install operating manual (parameters, escalations, merge)
│
├── examples/                                 ← (empty until the first real consumer validates V1)
├── CONTEXT.md                                ← the glossary — canonical vocabulary of the architecture
└── README.md                                 ← this file
```

### What lands in a consumer repository

```
consumer-repo/
├── PRD.md                        ← human-authored product intent (per feature) — the only file you write
├── .harness/                     ← every loop artifact lives here, one directory (ADR-014)
│   ├── loop/                     ← synced from the skill on every /loop-runtime invocation
│   ├── knowledge/                ← generated at first bootstrap; survives every run
│   ├── run/                      ← generated per run; machine-owned execution state; disposable
│   └── ISSUES.md                 ← problems only; survives the Cleanup Commit that removes run/
├── .claude/                      ← the CLI's own directory: installed skill + materialized agents
└── .agents/skills/loop-runtime/  ← installed by the skill installer (identical copy)
```

Each subdirectory of `.harness/` is a distinct lifecycle, which is what keeps the folder-level operations mechanical: install copies `loop/`, resetting a run deletes `run/`, and `knowledge/` survives both because it was never inside `run/`.

---

## How it works underneath (60 seconds)

1. **Bootstrap** (automatic — the first invocation finds no `.harness/run/`): the engine reads the PRD and the repository, generates `.harness/knowledge/` and `.harness/run/`, creates a dedicated `loop/<prd-slug>` branch, and stops with one question: *approve the Definition of Done*.
2. **The one mandatory human gate:** review the DoD (the testable meaning of "done") and the proposed toolchain capabilities. Answered as conversation now, not a hand-edited file.
3. **The loop runs unattended:** each iteration is a fresh process that recovers, orients from a small **Resume Block**, selects a **Phase** of up to three non-conflicting tasks, dispatches one **Worker** per task (each confined to a declared file scope, with no git/build/test capability), wires the shared files itself, builds and tests once, gets a **fresh-context review** on the combined diff, reconciles everything it learned, and commits **one atomic checkpoint** on one branch. Status `CONTINUE` → the runtime invokes it again.
4. **It does not stop for a question.** A decision above its authority is written to a **Decision Queue** naming the tasks it blocks; those tasks become unselectable and the loop carries on with unrelated work. A task that fails three attempts is **abandoned**, along with anything depending on it. The loop stops when it genuinely runs out of executable work (`ESCALATE`, a batch of questions to answer), when the environment is broken (`FAILED`), or when it reaches the **quota ceiling** — where it either waits for the usage window to reset and continues, or stops leaving you headroom.
5. **Completion is earned, not claimed:** the iteration that finishes the last task may not declare victory. A *fresh* verifier iteration — which wrote none of the code — re-proves every DoD criterion, strips the execution state from the branch tip (Cleanup Commit, whose message is the completion summary), and only then reports `DONE`.
6. **You merge.** The engine never touches your default branch and never merges. It may push its own `loop/*` branch if you granted that capability, which is how a mid-run machine failure stops costing you the work.

Full operating manual for the manual-install path (parameters, watching the loop, escalations, merge): [docs/consumer-guide.md](./docs/consumer-guide.md).

---

## Core design commitments

- **Stateless iterations, dumb runtime.** Every iteration starts from repository state, so resumability is *tested continuously*, not trusted. The runtime has no judgment — its whole intelligence is a status reaction table plus two mechanical safety bounds (crash watchdog, iteration budget).
- **Status contract.** Every engine invocation ends with exactly one of `CONTINUE / DONE / ESCALATE / FAILED`; producing no status *is* the crash signal. `ESCALATE` fires when work runs out, not at the first question.
- **Non-blocking progress.** Questions queue, failures abandon, and the loop keeps moving — which is what makes it usable with minimal supervision. Safety comes from the dependency graph: every queued question names the tasks it blocks, and a blocked task cannot be selected, so the engine can never build on an unanswered question.
- **Mechanical resource bounds.** Idle timeout (a working engine emits events continuously; silence is a hang), hard timeout, iteration budget, and a **quota ceiling read from structured signal** — the CLI's `rate_limit_event` reports utilization and reset time for *every* usage window, so the ceiling is measured rather than guessed, and hitting the limit is a wait rather than a crash.
- **Tiered mutability.** Tier 1: the engine freely reshapes tasks (always logged). Tier 2: architecture/strategy changes hard-stop for approval. Tier 3: intent belongs to the human, forever.
- **Capability-based permissions.** No permanent allowlists — grants carry intent, command, scope, and lifetime (goal-scoped by default, auto-expiring), enforced through the trust chain *Human → Ledger → Runtime Compiler → Settings → Engine*. A guardrail against accidents and drift — documented honestly as not being a boundary against an adversarial engine.
- **Three minds, plus Workers.** The builder implements, a clean-context reviewer challenges (it never sees the builder's reasoning — that reasoning may contain the original mistake), and a fresh verifier confirms completion. Parallel Workers are restricted by the harness, not by instruction: omitting `Bash` from a Worker's tool list is what makes "no git, no build, no test" real. The definitions live in `.harness/loop/agents/` and are republished each iteration, so the engine cannot loosen its own helpers.
- **Model tiered by role, named abstractly.** The Reviewer, the Verifier, and the Orchestrator always run at the Capable tier; a Worker's task may run at the cheaper Fast tier only when arm's-length planning roles — never the Worker itself — classify it as narrowly scoped with mechanically-checkable acceptance. A failed Fast-tier attempt escalates to Capable automatically. Neither `ENGINE.md` nor `POLICIES.md` ever names a vendor model — the mapping lives in one file, `.harness/loop/models.json`, which is what keeps porting to another engine a one-file edit ([ADR-013](./docs/adr/ADR-013-model-tiers-by-role.md)).
- **Bounded context, by construction.** Audit history leaves the read path entirely, so orientation cost stays flat instead of growing with the run: iteration 40 reads what iteration 2 read.
- **Everything auditable.** Plan amendments logged with reasons; human decisions recorded with rationale; every checkpoint a commit; the branch history *is* the execution history.
- **The skill never widens what the engine can do.** It stages input and supervises output; every capability grant — standing or goal-scoped — still flows through the same human-approved ledger the engine has always used.

The complete vocabulary lives in [CONTEXT.md](./CONTEXT.md); the full design in [docs/architecture.md](./docs/architecture.md); the reasoning behind each hard-to-reverse choice in [docs/adr/](./docs/adr/).

---

## Loop Engineering alignment

This is an application of Addy Osmani's [Loop Engineering](https://addyosmani.com/blog/loop-engineering/), which names six primitives a loop needs. Where each one lives here:

| Primitive | Where it lives |
|---|---|
| **Automations** (the heartbeat) | Deliberately *outside* `run.ps1` — the runtime holds no scheduling logic ([ADR-002](./docs/adr/ADR-002-stateless-iteration-dumb-runtime.md)). `run.ps1` is a goal loop; a cadence comes from Claude Code's `/loop`, cron, or CI invoking `/loop-runtime` |
| **Worktrees** (isolation) | Replaced by something stricter: one branch, one working directory, **Declared File Scopes verified after the fact** ([ADR-008](./docs/adr/ADR-008-phase-workers-single-branch.md)). Git refuses two worktrees on one branch, so the two are mutually exclusive — and verified scopes make a collision explicit instead of letting the filesystem hide it |
| **Skills** (codified knowledge) | The `/loop-runtime` skill, plus `.harness/knowledge/`, which survives every run |
| **Connectors** (real environment) | Any MCP rule string grants through the same Capability Ledger as a shell command — no new machinery, because the runtime concatenates approved rules verbatim |
| **Sub-agents** (maker/checker) | Builder, reviewer, verifier — plus Workers, restricted by the harness via `.harness/loop/agents/` |
| **State** (the spine) | `.harness/run/` + `.harness/knowledge/` + `git log`, with the read path split from the audit path ([ADR-010](./docs/adr/ADR-010-resume-block-and-audit-split.md)) |

The article's three warnings are answered by mechanisms rather than intentions: **verification stays human** (you merge, always), **comprehension debt** is fought by the completion summary and the Issues Report, and **cognitive surrender** is resisted by the DoD gate and Tier 3 — intent never becomes the machine's to decide.

Two places this goes further than the article: completion is certified by a mind that wrote none of the code, and the loop's resource bounds are read from structured signal rather than guessed at.

---

## When to use the loop — and when not to

The loop's per-iteration overhead is roughly **constant** (fresh-process orientation ~1 min, a build per checkpoint, review passes, one extra verification iteration). Its value — unattended execution, no context rot, crash resume, audited decisions, completion you don't have to verify yourself — **scales with feature size**. So the economics invert with task size:

| Task | Right tool |
|---|---|
| Small fix, one-file feature, anything you'd finish in one sitting | An interactive AI session — the loop's overhead dominates and it will feel slow |
| A real feature PRD (hours-to-days of work you'd otherwise prompt-and-review step by step) | The loop — the overhead amortizes and the guarantees take over |
| Anything you want to run unattended (overnight, while doing other work) | The loop — that's what it's for |

Don't judge the loop by a hello-world; judge it by unattended correctness on work you didn't want to babysit.

## Status

**V1 validated against its first real consumer** (Android Jetpack Compose project, hello-world-notification PRD, 2026-07-08). Every contract fired correctly in a real run: bootstrap → DoD escalation gate → capability grants → checkpoint commits with build evidence → fresh-context review → the engine invoking the DONE-Candidate rule on itself (refusing to self-certify and deferring completion to a clean verifier iteration).

**Skill packaging validated end-to-end** (scratch repo, hello-world-notification PRD, 2026-07-15): install → `/loop-runtime` → live background streaming → two real `ESCALATE`s handled as conversation (DoD/interpretation approval, then a capability grant) → `DONE` → roll-up summary, all without opening a single file by hand. One real bug found and fixed along the way: the skill's own frontmatter needed `disable-model-invocation: true`, otherwise a nested engine invocation running inside the same repo could see and auto-trigger the launcher skill on itself.

**V2 mechanisms validated against a real run** (Node.js two-command CLI, scratch repo, 2026-09-08). Bootstrap produced the full new scaffold — `RESUME.md` at 949 bytes (~237 tokens, the flat read-path artifact), `ISSUES.md` beside the run state, `HISTORY.md` split out of the read path — grouped both independent tasks into **one Phase with disjoint file scopes**, and correctly identified `src/cli.js` as the Iteration-owned shared integration file belonging to no Worker. It then queued its DoD decision naming the tasks it blocks and reported `ESCALATE` with the exact reasoning the design intends: *"No task is executable yet because D-001 blocks both tasks — the only work that exists."*

Prompt caching measured in that run: **94.8% and 86.3% cache-read** across iterations, which settles the concern in [ADR-010](./docs/adr/ADR-010-resume-block-and-audit-split.md) — the engine spec is billed at read rates, so its size is not the thing to optimize.

Four defects the run surfaced and that are now fixed, three of which no fixture-based test would have caught:

- **`--agents` JSON could not survive the shim chain.** The npm `claude` is itself a PowerShell script that re-quotes its arguments, and PowerShell 5.1 mangles embedded double quotes at that hop. Agent definitions are now files in `.harness/loop/agents/`, materialized into `.claude/agents/` each iteration — no command-line quoting at all.
- **A generated path contained a stray control character**, creating a differently-named directory so Workers were silently never registered. The run reported no error at all. Verification now rejects every control character, not just non-ASCII.
- **`rate_limit_event.status` has three values**, not two: `allowed`, `allowed_warning`, `rejected`. Treating "not allowed" as a rejection would sleep for hours on an invocation that merely crashed while near the limit.
- **The quota ceiling cannot preempt one expensive iteration.** A single iteration went from ~40% to 100% of the window. The runtime now tracks the peak seen mid-stream and acts on the CLI's own warning, but the ceiling remains a guard on *starting* an iteration — so set it lower than 90% when iterations are costly.

Field findings driving the next iteration of the runtime:

- **Compound Bash commands can get denied even when the base command is capability-approved** (e.g. `cd X && node ...`) — the engine self-corrected by retrying with simpler forms both times this was hit; worth tightening the capability-proposal format so this doesn't cost a retry.
- **Plan granularity must scale with PRD size** — bootstrap split a 2-task feature into 5 tasks, multiplying the per-iteration overhead. Addressed by Phase grouping ([ADR-008](./docs/adr/ADR-008-phase-workers-single-branch.md)): grouping tasks into Phases is what cuts iteration count, which is where orientation cost is paid.
- Observability must never kill execution — a log-tail file lock once crashed the whole loop; log writes are now shared-mode and fail-silent, and a run lock allows only one runtime per repository (fixed).
- Iteration counters differ between engine (counts from STATE, includes bootstrap) and runtime (counts this session's invocations) — cosmetic, pending alignment.
- Console shows mojibake for UTF-8 punctuation on default Windows code pages — cosmetic, pending `[Console]::OutputEncoding` fix.
- Multi-engine portability (Codex, Gemini) is architecturally confined to one adapter surface in `run.ps1` — see [ADR-006](./docs/adr/ADR-006-engine-adapter-boundary.md).

The repository stays intentionally small: additional structure earns its way in through real usage, not anticipated complexity. Deferred items and their revisit-triggers: [docs/architecture.md §12](./docs/architecture.md).
