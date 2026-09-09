# Consumer Guide — operating the loop in your repository

How to install, run, and govern Foreman as the human in the loop. Design rationale lives in [architecture.md](./architecture.md); this is the operating manual.

There are two ways to operate the loop — pick one per repository, both talk to the same engine underneath:

- **Skill path (recommended)** — the `/foreman` Claude Code skill installs, stages, launches, supervises, and summarizes for you. This is the path most people want; skip to [§1a](#1a-install-the-skill-recommended).
- **Manual path** — copy `.harness/loop/` yourself and run `run.ps1` from a terminal. Useful outside Claude Code, for scripted/CI-style invocation, or if you want direct control over every parameter. See [§1b](#1b-install-manually).

---

## Prerequisites

- A git repository (clean working tree recommended before starting a run)
- Claude Code CLI installed and authenticated
- Windows PowerShell (V1 ships `run.ps1`; the contract is shell-agnostic)
- Skill path only: Node.js available (for `npx`)

## 1a. Install the skill (recommended)

```
npx skills@latest add Phong-Kaster/foreman
```

Installs `foreman` into `.claude/skills/foreman/` and `.agents/skills/foreman/` in the current repo. Nothing else to copy — the skill carries its own copy of `ENGINE.md`, `POLICIES.md`, the capability baseline, the templates, and `run.ps1`, and materializes `.harness/loop/` at your repo root itself the first time you invoke it.

## 1b. Install manually

Copy the `.harness/loop/` directory into your repository root by hand. That is the entire installation — never edit its contents per-project (project-specific truth belongs in `.harness/knowledge/`, which the loop maintains itself). Use this path if you're not working inside Claude Code, or want to invoke `run.ps1` from a script/CI job instead of a conversation.

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
| `-MaxIdleMinutes` | 20 | No engine event for this long = a hung iteration; killed and treated as a crash. Must exceed your longest single command (a clean Android build can pass 10 minutes) |
| `-MaxIterationMinutes` | 90 | Hard backstop for an iteration that emits events but never converges |
| `-QuotaStopPercent` | 90 | Stop (or wait) at this usage-window utilization, on **whichever window trips first** |
| `-NoQuotaWait` | off | Stop at the quota ceiling instead of sleeping until it resets |
| `-MaxQuotaWaits` | 6 | How many resets one run may wait through before stopping deterministically |
| `-NoStablePrompt` | off | Opt out of keeping per-iteration sections out of the system prompt (they are excluded by default so the cacheable prefix stays identical between iterations) |
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

## 5. While the loop runs

Nothing is required from you. The loop stops only for:

- **`ESCALATE`** — the loop ran out of executable work and needs decisions. It does **not** stop at the first question: a question is queued with the tasks it blocks named, and the loop continues on unrelated work ([ADR-007](./adr/ADR-007-non-blocking-progress.md)). So expect a **batch** of questions here, not one. Skill path: answered as conversation, same as §4. Manual path: read `.harness/run/ESCALATION.md`, fill the `## Decision` section of any entries you want to answer (a subset is fine), re-run.
- **Abandoned tasks** — a task failing three attempts is abandoned, along with anything depending on it, and the loop keeps going. This is what lets it run with little supervision. A run with an abandoned task reports `ESCALATE`, never `DONE`, and never runs the verifier: an incomplete feature is not certified. Read `ISSUES.md` for what failed and why.
- **Quota ceiling (exit 6)** — stopped to leave usage headroom, or waited too many resets. Re-run after the window resets.
- **`FAILED`** — execution itself is broken (environment, corruption, exhausted resources). Fix the environment, re-run (or ask the skill to); the engine resumes from the last checkpoint.
- **Watchdog / budget stops** — mechanical bounds tripped. Inspect, re-run to continue; the loop never loses verified work.

Interrupting is always safe: kill it whenever you like (or ask the skill to stop supervising). Every iteration ends at a Stable Checkpoint (one atomic commit of code + state); the next invocation recovers mechanically — even from a mid-iteration crash, which it detects as a dirty working tree.

**The run is tied to the session that launched it.** If you close the terminal (or the Claude Code session ends), the loop stops. That is deliberate and costs nothing: re-run and it continues from the last checkpoint. There is no separate resume step.

**The loop occupies the working directory** for the whole run — one branch, one checkout ([ADR-008](./adr/ADR-008-phase-workers-single-branch.md)). You cannot work in that repository concurrently. Use a second clone if you need to.

**On hitting the usage limit** the run does not die. It reads the reset time from the CLI's own rate-limit signal, logs a heartbeat while it sleeps (`waiting for quota reset — HH:MM:SS remaining`), then continues. It also stops *before* the limit — at 90% by default — to leave you headroom, since a loop that consumes your whole window leaves you none for your own work. Both usage windows are checked, not just the five-hour one: exhausting the weekly window locks you out for days rather than hours.

**Set `-QuotaStopPercent` lower than you would expect.** The ceiling governs whether the loop *starts another* iteration, not whether it finishes the current one — and one iteration can consume a large slice of the window on its own. A measured run went from roughly 40% to 100% inside a single iteration. The runtime mitigates this by acting on the CLI's own near-limit warning rather than only on its own arithmetic, but no threshold can preempt an iteration already in flight. If your iterations are expensive, 60–70% is a more realistic ceiling than 90%.

**Read `.harness/ISSUES.md`.** It is regenerated every iteration and contains problems only: tasks the loop abandoned after three attempts (with each attempt's command and error), tasks it could not reach, decisions waiting on you, review findings it recorded but did not fix, and assumptions it made. It survives to the end of the run, unlike `.harness/run/`.

Watching progress: `git log --oneline` on the loop branch is the execution history; `.harness/run/STATE.md` is the engine's current memory; `.harness/run/AMENDMENTS.md` is the audited log of every plan mutation.

**Capability grants can be goal-scoped, not just standing.** A denied-but-needed action (e.g. a destructive git operation the engine isn't authorized for, even late in a run) escalates the same way — the request can propose either a standing capability (`.harness/knowledge/capabilities.json`, survives future runs) or a one-time, goal-scoped one (`.harness/run/capabilities.json`, expires automatically when `.harness/run/` is removed at completion). Prefer goal-scoped whenever the need is specific to this one run.

## 6. Completion and merge

`DONE` is only ever reported by a fresh verifier iteration that wrote none of the implementation and re-proved every DoD criterion. At that point the branch tip contains the implementation, updated `.harness/knowledge/`, and a **Cleanup Commit** whose message is the completion summary (criteria → evidence, notable amendments) — and no `.harness/run/` (execution state is the loop's memory, not your product; its full history remains in the branch's earlier commits).

**Skill path:** you get a roll-up summary across **every** `loop/*` branch in the repo, not just the one that finished — each one's status (done / in-progress / stuck on an escalation / stale), what it contains, and whether it's merge-ready — plus any non-blocking review notes that would otherwise be lost when `.harness/run/` is deleted.

**Manual path:** review the branch like any contribution yourself; check other `loop/*` branches with `git branch --list 'loop/*'` if you've run more than one goal in this repo.

Either way: **merging is your act — the engine never merges and never touches your default branch.** It may push its own `loop/*` branch, and only that, if you granted the capability.

## 7. The next feature

**Skill path:** `/foreman <next requirement>` — same repo, new goal. If a `PRD.md` already exists and differs from the new text, the skill confirms with you before overwriting rather than doing it silently.

**Manual path:** write a new `PRD.md`, run `run.ps1` again. Either way, `.harness/knowledge/` persists — verified commands and hard-won environmental lessons carry over; a new `.harness/run/` and a new loop branch are created for the run.

To abandon a run: delete `.harness/run/` and the loop branch. Nothing else to clean.

---

## What the engine may never do

Enforced mechanically (runtime deny rules) or by hard-stop protocol — true regardless of which path launched it:

- Modify `.harness/loop/`, any capability ledger, or its own permission settings
- Modify `PRD.md` or the approved `DoD.md`
- Widen a capability beyond what you approved
- Touch your default branch, merge, or rewrite history (`--force`, `rebase` and `merge` are denied outright by the runtime, whatever any allow rule says)
- Push anything without an explicit capability grant, and even then only the `loop/*` branch
- Declare `DONE` from the same invocation that implemented the final work
- Declare `DONE` at all if any task was abandoned or any decision is unanswered
- Proceed on a task blocked by an unanswered decision, or one depending on an abandoned task
- Give a Worker git, build, or test access (enforced by the `tools:` list in `.harness/loop/agents/`, republished into `.claude/agents/` every iteration and deny-listed against the engine's own edits, so it cannot loosen its own helpers)

The skill adds no authority of its own on top of this — it only stages input (PRD, capability ledger entries you already approved) and supervises/summarizes output. Every capability the engine ever exercises still traces back to a ledger entry you approved, standing or goal-scoped.

## Honest limitations

- The capability system is a guardrail against accidents and drift — not containment for an adversarial process. For untrusted PRDs or maximum isolation, run the whole loop inside a VM/container (where `-DangerouslySkipPermissions` becomes reasonable).
- **Network access is now part of the capability surface**: `git push` of the Loop Branch can be granted ([ADR-011](./adr/ADR-011-loop-branch-push.md)). It is High-risk by classification and off unless you grant it. Granting it means the loop's unverified intermediate checkpoints become visible on your remote and may trigger CI. The default branch, `--force`, `merge` and `rebase` remain denied regardless.
- V1 assumes git and PowerShell; both are persistence/transport details, not architecture.
- Compound Bash commands (e.g. `cd <dir> && node ...`) can be denied even when the base command is capability-approved, since the approval matches on the literal command form. Expect the engine to self-correct by retrying with a simpler form — it costs a retry, not a failure.
- Skill path only: the skill's own frontmatter must keep `disable-model-invocation: true`. Without it, a nested engine invocation running inside the same repo can see the skill and auto-trigger it on itself instead of following `ENGINE.md` directly — this was a real bug found during testing, now fixed, but worth knowing if you ever fork or repackage the skill.
- Automated agent-skill security scanners on skill installers (e.g. Snyk, Socket) rate this skill High-risk, and correctly so — this is an accurate read of its real capability surface, not a false positive: the baseline capability ledger (`capabilities/baseline.json`) grants `Edit(**)`, `Write(**)`, and git commit/branch/checkout as **permanent, automatic** capabilities — no per-action approval once a run starts; `run.ps1` ships a `-DangerouslySkipPermissions` switch that fully bypasses the permission system (documented for sandboxed/VM use only); and the engine runs unattended for up to 50 iterations, writing and committing code on its own branch with a human in the loop only at escalations. Consistent with this project's own documented position (ADR-004): a guardrail against accidents and drift, not a security boundary against an adversarial engine. Since [ADR-011](./adr/ADR-011-loop-branch-push.md) the surface also includes **network access**: `git push` of the `loop/*` branch is grantable, and granting it publishes unverified intermediate checkpoints to your remote where CI may run on them. It is off unless you grant it. The mitigations that make this an acceptable tradeoff are independently verifiable in the same files: the engine never touches the default branch, never merges, and cannot force-push or rebase (the runtime appends deny rules for `git push --force`, `git push -f`, `git merge` and `git rebase` that no allow rule can override); `.harness/loop/`, all capability ledgers, and generated permission settings are deny-listed against the engine's own edits; and it escalates for any capability grant or architecture/intent change rather than expanding its own authority.
