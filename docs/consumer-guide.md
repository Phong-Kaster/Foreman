# Consumer Guide — operating the loop in your repository

How to install, run, and govern Foreman as the human in the loop. This is the reference manual: every parameter, both install paths, and the engine's hard limits.

- New here? Start with the [README](../README.md) — same material, plain language, decision-first.
- Want the reasoning rather than the procedure? [architecture.md](./architecture.md), and [docs/adr/](./adr/) for each hard-to-reverse choice.
- Vocabulary: [CONTEXT.md](../CONTEXT.md).

There are two ways to operate the loop — pick one per repository, both talk to the same engine underneath:

- **Skill path (recommended)** — the `/foreman` Claude Code skill installs, stages, launches, supervises, and summarizes for you. This is the path most people want; skip to [§1a](#1a-install-the-skill-recommended).
- **Manual path** — copy `.harness/loop/` yourself and run `run.ps1` from a terminal. Useful outside Claude Code, for scripted/CI-style invocation, or if you want direct control over every parameter. See [§1b](#1b-install-manually).

---

## Prerequisites

- **A git repository** — every Stable Checkpoint is a commit. Start from a clean working tree: the engine reads uncommitted changes at iteration start as debris from a crashed invocation and will salvage or discard them.
- **Claude Code CLI, installed and authenticated** — the runtime invokes `claude` once per iteration. If it is not on `PATH`, `run.ps1` produces no status and the Watchdog stops the run.
- **Windows PowerShell** — V1 ships `run.ps1` only; the contract itself is shell-agnostic (a `run.sh` waits for the first non-Windows consumer).
- **Node.js** — skill path only, for `npx`. The loop does not need it; your project may.

## 1a. Install the skill (recommended)

```
npx skills@latest add Phong-Kaster/Foreman
```

Installs `foreman` into `.claude/skills/foreman/` and `.agents/skills/foreman/` in the current repo. Nothing else to copy — the skill carries its own copy of `ENGINE.md`, `POLICIES.md`, the capability baseline, the templates, and `run.ps1`, and materializes `.harness/loop/` at your repo root itself the first time you invoke it.

## 1b. Install manually

Copy the `.harness/loop/` directory into your repository root by hand. That is the entire installation — never edit its contents per-project (repository-specific truth belongs in `.harness/knowledge/PROJECT.md`, which the loop maintains itself; domain rules belong in `.harness/knowledge/DOMAIN.md`, which only you write). Use this path if you're not working inside Claude Code, or want to invoke `run.ps1` from a script/CI job instead of a conversation.

---

## 2. Provide the requirement

**Skill path:** type one of:

```
/foreman <inline requirement text>
/foreman <path to a requirement document>
/foreman
```

Inline text is written verbatim into `PRD.md` — no rewriting, no summarizing. A path to an existing file gets staged as the PRD source instead (via `run.ps1 -PrdPath`). No argument resumes whatever `PRD.md` already exists, or asks you for one if there isn't one yet.

**Manual path:** create `PRD.md` at the repository root yourself — business objective, requirements, constraints. Write it for a competent engineer who cannot ask you questions in real time — ambiguity you leave here either becomes a recorded assumption or an escalation that stops the loop.

## 3. Start the runtime

**Skill path:** the skill starts it for you — `.harness/loop/run.ps1` is launched in the background and its log is streamed live into the conversation via a Monitor, the same way you'd see output from any other command. Nothing to run by hand; nothing ties up your terminal, and there's no foreground-command timeout to worry about on a long run.

**Manual path:**

```powershell
powershell -File .harness/loop/run.ps1
```

Useful parameters:

| Parameter | Default | Purpose |
|---|---|---|
| `-MaxIterations` | 50 | Iteration budget per run — deterministic safety stop, not a judgment |
| `-MaxConsecutiveCrashes` | 3 | Watchdog bound for invocations that die without reporting |
| `-PrdPath` | (empty) | Stage an external file as `PRD.md` before the first iteration — relative or absolute path |
| `-Model` | (CLI default) | Model override for engine invocations |
| `-QuietEngine` | off | Suppress the live engine activity feed |
| `-DangerouslySkipPermissions` | off | Full permission bypass — only for sandboxed/VM environments |

### Watching the loop (is it running?)

**Skill path:** the conversation itself is the live view — every line `run.ps1` writes (iteration headers, engine tool-use, engine text, `Status:` lines) streams in as it happens. Ask at any time and you'll get a summary of where the run currently stands.

**Manual path:** the terminal that launches `run.ps1` owns the live view: a timestamped activity feed with a per-iteration stopwatch, one line per engine action —

```
=== Iteration 2 / 50 === started 20:35:30 | total elapsed 00:04:44
[20:35:41 +00:00:10] engine> Read .ai\STATE.md
[20:36:02 +00:00:31] engine> Bash ./gradlew.bat assembleDebug
Status: CONTINUE (iteration took 00:04:44, total elapsed 00:09:28)
```

New lines appearing = the loop is alive; the `+HH:MM:SS` stopwatch shows how deep into the iteration it is.

To follow the same feed from **any other terminal** (the runtime prints both log paths at startup):

```powershell
# clean, human-readable activity feed (safe to tail while the loop runs)
Get-Content "$env:TEMP\loop-run-<repo-name>.log" -Wait -Tail 20

# raw engine event stream — debugging only
Get-Content "$env:TEMP\loop-run-<repo-name>.raw.jsonl" -Wait -Tail 5
```

The `engine>` / `engine:` lines are identical in both places, but the file's iteration and status headers carry a full ISO timestamp rather than the console's stopwatch phrasing — the same feed, formatted for a log rather than a terminal:

```
=== Iteration 2 / 50 === 2026-09-09T20:35:30.4821637+07:00
[20:36:02 +00:00:31] engine> Bash ./gradlew.bat assembleDebug
=== Status: CONTINUE === 2026-09-09T20:44:58.9930412+07:00
```

Other quick liveness checks:

```powershell
# is an engine invocation alive right now?
Get-Process claude -ErrorAction SilentlyContinue | Sort-Object StartTime | Select-Object -Last 3

# what has the loop committed so far?
git log --oneline loop/<prd-slug>
```

Only one runtime may run per repository — a second `run.ps1` refuses to start while another holds the run lock (`$env:TEMP\loop-run-<repo-name>.lock`; stale locks from dead processes are taken over automatically). This holds regardless of which path launched it.

The first invocation finds no `.harness/run/` and therefore bootstraps: it reads your PRD, inspects the repository (including `CLAUDE.md` and READMEs — it never edits them), generates `.harness/knowledge/` and `.harness/run/`, creates the `loop/<prd-slug>` branch, and stops with `ESCALATE`.

## 4. The one mandatory gate: approve the Definition of Done

**Skill path:** the skill reads `.harness/run/ESCALATION.md` and asks you directly in conversation — the DoD, the proposed capabilities, and any ambiguity the engine flagged, presented as a normal question with the engine's own considered options as choices. Answer it like any other question; the skill writes your decision (and rationale) into `.harness/run/ESCALATION.md`'s `## Decision` section and any approved capability into the right ledger file, then resumes automatically. You never open a file yourself.

**Manual path:** open `.harness/run/DoD.md` and `.harness/run/ESCALATION.md`. The DoD is the exam the whole run will be graded against — this is your highest-leverage five minutes:

1. Edit the criteria freely: tighten vague ones, delete wrong ones, add missing ones. Every criterion must be provable by evidence.
2. Review the proposed standing capabilities (your repo's build/test/lint commands). Narrow anything too broad; paste approved entries into the named ledger file.
3. Write your decision **and rationale** under `## Decision` in `.harness/run/ESCALATION.md`.
4. Re-run `run.ps1`.

After approval the DoD is immutable to the engine either way: it may propose changes, never apply them.

### The other file you own: `.harness/knowledge/DOMAIN.md`

Optional, and only worth creating if your project has **durable domain rules** — a formula, an algorithm, a regulatory or business invariant. Blood-pressure maths; the tolerances a background-removal algorithm must hold to; what "active subscriber" is defined to mean this quarter.

It matters because of one inverted rule. `.harness/knowledge/PROJECT.md` is a cache of facts *about* your code, so when they disagree, the code wins and the engine fixes the file. `DOMAIN.md` is the opposite: your code is an *attempt* at the rule, so when they disagree, **the rule wins and the code is a defect**. Without that inversion, an engine finding a wrongly-implemented formula would "correct" the correct formula to match the bug — and then the fresh-context reviewer, which is handed your domain rules as its standard, would validate every later change against the corruption.

So the engine is **deny-listed** from writing it, mechanically, the same as the Capability Ledgers. It reads the file, implements what is written, reports code that contradicts it, and proposes new entries through an Escalation Request. You (or the skill, transcribing a decision you approved) do the writing.

Practically:

- Start from `.harness/loop/templates/DOMAIN-KNOWLEDGE.template.md`. State each rule precisely enough to be implemented and tested from that text alone, and cite the authority so it can be re-checked later.
- Be explicit about units, valid ranges and boundary behaviour. That is where implementations silently diverge.
- Don't create an empty one. No domain rules means no file — a stub is clutter that every iteration reads.
- Don't put general stack knowledge here ("Android 13 changed notification permissions"). That is not truth about *your* project, nothing in your repo can verify it, and it goes stale with nothing to correct it — see [ADR-019](./adr/ADR-019-knowledge-stratification-and-ratchet.md).

## 5. While the loop runs

Nothing is required from you. There are exactly five ways a run ends, and `run.ps1` exits with a distinct code for each — the codes are the contract for scripted or CI invocation:

| Ending | Exit | Meaning | Your move |
|---|---|---|---|
| `DONE` | 0 | Goal verified complete by a fresh verifier iteration. | Review and merge — §6. |
| `ESCALATE` | 3 | A decision above the engine's authority: an architecture change (Tier 2), an intent gap (Tier 3), a capability request, missing product information. | Skill path: answer in conversation, as in §4. Manual path: read `.harness/run/ESCALATION.md`, write decision + rationale under `## Decision`, re-run. One pending escalation at a time, always. |
| `FAILED` | 4 | Execution itself is broken — environment, repository corruption, exhausted resources. Not "the task was hard". | Repair the environment, re-run (or ask the skill to). The engine resumes from the last checkpoint. |
| Watchdog | 2 | `MaxConsecutiveCrashes` (default 3) invocations died without producing any status. | Usually a transient CLI/network fault. Inspect `.harness/run/STATE.md`, re-run. |
| Budget | 5 | `MaxIterations` (default 50) exhausted. A deterministic safety stop, never an interpretation of task failure. | Inspect `.harness/run/STATE.md` for actual progress, then re-run to continue — or raise `-MaxIterations`. |

Exit code `1` is a prerequisite failure before any engine invocation: `.harness/loop/ENGINE.md` missing (wrong working directory), a `-PrdPath` that does not resolve, or another runtime already holding the run lock.

Interrupting is always safe: kill it whenever you like (or ask the skill to stop supervising). Every iteration ends at a Stable Checkpoint (one atomic commit of code + state); the next invocation recovers mechanically — even from a mid-iteration crash, which it detects as a dirty working tree.

Watching progress: `git log --oneline` on the loop branch is the execution history; `.harness/run/STATE.md` is the engine's current memory; `.harness/run/AMENDMENTS.md` is the audited log of every plan mutation.

**Capability grants can be goal-scoped, not just standing.** A denied-but-needed action (e.g. a destructive git operation the engine isn't authorized for, even late in a run) escalates the same way — the request can propose either a standing capability (`.harness/knowledge/capabilities.json`, survives future runs) or a one-time, goal-scoped one (`.harness/run/capabilities.json`, expires automatically when `.harness/run/` is removed at completion). Prefer goal-scoped whenever the need is specific to this one run.

## 6. Completion and merge

`DONE` is only ever reported by a fresh verifier iteration that wrote none of the implementation and re-proved every DoD criterion. At that point the branch tip contains the implementation, updated `.harness/knowledge/`, and a **Cleanup Commit** whose message is the completion summary (criteria → evidence, notable amendments) — and no `.harness/run/` (execution state is the loop's memory, not your product; its full history remains in the branch's earlier commits).

**Skill path:** you get a roll-up summary across **every** `loop/*` branch in the repo, not just the one that finished — each one's status (done / in-progress / stuck on an escalation / stale), what it contains, and whether it's merge-ready — plus any non-blocking review notes that would otherwise be lost when `.harness/run/` is deleted.

**Manual path:** review the branch like any contribution yourself:

```powershell
git branch --list 'loop/*'              # every run this repository has done
git log --oneline loop/<prd-slug>       # the execution history, one commit per iteration
git log -1 loop/<prd-slug>              # the Cleanup Commit: completion summary, criteria -> evidence
git diff <default-branch>...harness/loop/<prd-slug>   # the whole change, as one review
git merge loop/<prd-slug>
```

The three-dot form is deliberate: it diffs the branch against the point it diverged from, so unrelated commits landing on your default branch meanwhile don't pollute the review.

**What the run knew was still wrong** is recorded as **Constraints** in `.harness/knowledge/PROJECT.md` — defects the engine found and did not fix, because they were out of scope, because a review finding was filed rather than resolved, or because you deferred them. A Constraint is carried verbatim into every Worker Brief and checked against every diff, so a later run does not reproduce the defect. Each is written as an instruction (*"never do X here, because Y"*) and cites `file:line`. Prune one once it is resolved — a stale Constraint misleads worse than a missing one.

Separately, `.harness/ISSUES.md` is the **Issues Report**: regenerated every iteration for you, not for the engine, listing what is stuck — abandoned tasks, queued decisions, and `human` criteria still unsigned. It survives the Cleanup Commit so a stopped run is legible when you come back to it.

Either way: **merging is your act — the engine never merges, never pushes, never touches your default branch.**

## 7. The next feature

**Skill path:** `/foreman <next requirement>` — same repo, new goal. If a `PRD.md` already exists and differs from the new text, the skill confirms with you before overwriting rather than doing it silently.

**Manual path:** write a new `PRD.md`, run `run.ps1` again. Either way, `.harness/knowledge/` persists — verified commands and hard-won environmental lessons carry over; a new `.harness/run/` and a new loop branch are created for the run.

To abandon a run: delete `.harness/run/` and the loop branch. Nothing else to clean.

---

## What the engine may never do

Enforced mechanically (runtime deny rules) or by hard-stop protocol — true regardless of which path launched it:

- Modify `.harness/loop/`, any capability ledger, `.harness/knowledge/DOMAIN.md`, or its own permission settings
- Modify `PRD.md` or the approved `DoD.md`
- Widen a capability beyond what you approved
- Touch your default branch, push, merge, or rewrite history
- Declare `DONE` from the same invocation that implemented the final work
- Proceed past an unanswered escalation

The skill adds no authority of its own on top of this — it only stages input (PRD, capability ledger entries you already approved) and supervises/summarizes output. Every capability the engine ever exercises still traces back to a ledger entry you approved, standing or goal-scoped.

## Honest limitations

- The capability system is a guardrail against accidents and drift — not containment for an adversarial process. For untrusted PRDs or maximum isolation, run the whole loop inside a VM/container (where `-DangerouslySkipPermissions` becomes reasonable).
- V1 assumes git and PowerShell; both are persistence/transport details, not architecture.
- Compound Bash commands (e.g. `cd <dir> && node ...`) can be denied even when the base command is capability-approved, since the approval matches on the literal command form. Expect the engine to self-correct by retrying with a simpler form — it costs a retry, not a failure.
- Skill path only: the skill's own frontmatter must keep `disable-model-invocation: true`. Without it, a nested engine invocation running inside the same repo can see the skill and auto-trigger it on itself instead of following `ENGINE.md` directly — this was a real bug found during testing, now fixed, but worth knowing if you ever fork or repackage the skill.
- Automated agent-skill security scanners on skill installers (e.g. Snyk, Socket) rate this skill High-risk, and correctly so — this is an accurate read of its real capability surface, not a false positive: the baseline capability ledger (`capabilities/baseline.json`) grants `Edit(**)`, `Write(**)`, and git commit/branch/checkout as **permanent, automatic** capabilities — no per-action approval once a run starts; `run.ps1` ships a `-DangerouslySkipPermissions` switch that fully bypasses the permission system (documented for sandboxed/VM use only); and the engine runs unattended for up to 50 iterations, writing and committing code on its own branch with a human in the loop only at escalations. Consistent with this project's own documented position (ADR-004): a guardrail against accidents and drift, not a security boundary against an adversarial engine. The mitigations that make this an acceptable tradeoff are independently verifiable in the same files: the engine never touches the default branch, never pushes, never merges, never force-pushes or rebases; `.harness/loop/`, all capability ledgers, and generated permission settings are deny-listed against the engine's own edits; and it escalates for any capability grant or architecture/intent change rather than expanding its own authority.
