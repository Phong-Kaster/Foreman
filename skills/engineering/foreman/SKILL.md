---
name: foreman
description: Start or resume the Foreman engine in this repo, from inline requirement text or a path to a requirement document. Supervises the run live, handles ESCALATE gates as normal conversation instead of manual file edits, and reports a roll-up summary of all loop branches when done. Prefix --auto or --collab to choose the Run Mode (with optional --hours N / --iterations N budgets), or pass `mode auto|collab` to switch a run in progress.
disable-model-invocation: true
---

The user's raw input (inline requirement text, OR a path to a requirement document, OR empty,
optionally preceded by a mode flag — OR a `mode` command) is:

$ARGUMENTS

Follow these steps in order. Do not skip steps or add interpretation beyond what's specified.

## 0. Run Mode (ADR-027)

A run is either **Collaborative** (important decisions stop for the user) or **Autonomous** (the
engine decides alone and reports everything at the end). The mode lives in `<git-dir>/foreman-mode`,
where `<git-dir>` is the output of `git rev-parse --absolute-git-dir` — outside the working tree on
purpose, so switching it never leaves a change the engine would revert as crash debris. The engine
is denied write access to it; only the user, through this skill, changes it.

Trim $ARGUMENTS and check, in this order:

- **It is `mode` alone** → report the current mode (the file's first line; missing means
  Collaborative) and whether a run is in progress (`.harness/run/` exists). Stop.
- **It is `mode auto` / `mode autonomous` / `mode collab` / `mode collaborative`** → this is a
  switch, not a launch.
  - If `.harness/run/` does not exist, no run is in progress to switch, and the next launch starts
    Collaborative unless told otherwise. Do not write the file; tell the user to launch with
    `/foreman --auto <requirement>` instead. Stop.
  - Otherwise write `Autonomous` or `Collaborative` as the file's only line. If a run is live (a
    Monitor is attached, or the runtime's lock file `%TEMP%\loop-run-<repo-folder-name>.lock` names
    a live PID), tell the user it takes effect at the **next** iteration — the one in flight
    finishes under the old mode — and that the stream will print `mode switched: ...`. If no run is
    live, tell the user the mode applies when they next run `/foreman`. Stop.
- **It starts with flags** → consume leading tokens, in any order, while they are one of:
  - `--auto` / `--collab` → remember the mode (`Autonomous` / `Collaborative`);
  - `--hours <n>` → remember an hour budget (a positive number) for `-MaxHours`;
  - `--iterations <n>` → remember an iteration budget (a positive whole number) for `-MaxIterations`.

  Stop at the first token that is none of these. The remainder is the input for step 3 —
  requirement text or a path, exactly as if the flags were not there. A budget flag without a valid
  number is an error: stop and tell the user which flag was malformed.
- **Anything else** → no flags. Continue to step 1. The runtime keeps a run-in-progress's mode, and
  starts a new run Collaborative.

An Autonomous run never stops to ask after the DoD approval, so its budgets are the only thing that
ends it early. When a new run is launched with `--auto` and no `--hours`, tell the user the run is
bounded only by the default 50 iterations, and that `--hours <n>` adds a wall-clock limit.

## 1. Locate the installed runtime files

Check `.claude/skills/foreman/` and `.agents/skills/foreman/` (identical copies) —
use whichever exists; call it `<SkillDir>` below. It contains `ENGINE.md`, `POLICIES.md`,
`models.json`, `agents/`, `bin/`, `capabilities/baseline.json`, `templates/`, `scripts/run.ps1`.

## 2. Sync .harness/loop/ at the repo root

Copy `<SkillDir>/ENGINE.md`, `POLICIES.md`, `models.json`, `agents/`, `bin/`, `capabilities/`, `templates/`, and
`scripts/run.ps1` (as `.harness/loop/run.ps1`) into `.harness/loop/` at the repository root, overwriting existing
copies there.
Never touch `.harness/run/`, `.harness/knowledge/`, or `PRD.md` — those are per-repo runtime state, not part of
the distributable, and must survive across skill updates untouched.

## 3. Resolve the PRD input

Take the input left after step 0 removed any flags, trimmed.

- Resolves to an existing file on disk → this is a **document path**. Note its full resolved
  path — pass it to the runtime as `-PrdPath`. Do not read or alter the file's content.
- Does NOT exist as a file, but looks path-like (contains `\` or `/`, a drive-letter pattern like
  `X:`, or ends in a file extension such as `.md`/`.txt`/`.docx`) → STOP. Tell the user the path
  was not found and ask them to correct it or provide plain requirement text instead.
- Otherwise → this is **inline requirement text**. Write the argument verbatim (no rewriting, no
  summarizing, no expanding) into `PRD.md` at the repo root.
- $ARGUMENTS is empty and `PRD.md` already exists at the repo root → proceed directly with it.
- $ARGUMENTS is empty and no `PRD.md` exists → stop and ask the user for requirement text or a
  document path. Do not start the runtime without a PRD.

If `PRD.md` already exists and its content is identical to new inline text, skip writing. If it
exists and differs, ask the user to confirm before overwriting — never overwrite silently.

## 4. Launch the runtime

Run from the repository root, via the Bash tool with `run_in_background: true` (this must not be
a foreground/blocking call — a full run can exceed the foreground command timeout):

- Document-path case: `powershell -File .harness/loop/run.ps1 -PrdPath "<resolved path from step 3>"`
- Inline-text / existing-PRD.md case: `powershell -File .harness/loop/run.ps1`

If step 0 found a mode flag, append `-Mode Autonomous` or `-Mode Collaborative`. Without a flag,
pass no `-Mode` at all — passing one would overwrite a switch the user made with `/foreman mode`.
Append `-MaxHours <n>` and `-MaxIterations <n>` for the budget flags step 0 found.

Tell the user it started, which mode it is running in (every iteration header in the log ends with
`| mode <Mode>`), and note the log path it prints (`%TEMP%\loop-run-<repo-folder-name>.log`).

## 5. Supervise live

Immediately attach a Monitor to the same log file (`tail -f` on the path from step 4), unfiltered,
with `persistent: true` — a run can take a long time. Every line `run.ps1` writes (iteration
headers, `engine>` tool-use lines, `engine:` text snippets, `Status:` lines) now streams into the
conversation live, the same as any other command's output.

You do **not** need to keep your own notes of non-blocking findings any more: the engine
regenerates `.harness/ISSUES.md` every iteration, and that file survives the Cleanup Commit.
Read it rather than reconstructing it.

Two new stream lines are normal and are **not** failures — do not stop the monitor for either:

- `waiting for quota reset — HH:MM:SS remaining` — the run hit the usage ceiling and is sleeping
  until the window resets, then continuing on its own (ADR-012). Tell the user when it resumes.
- `Crash detected (idle timeout)` / `(hard timeout)` — a hung iteration was killed; the Watchdog
  re-invokes and the next iteration recovers from the last checkpoint.
- `mode switched: <old> -> <new>` — the user switched the run with `/foreman mode ...`; tell them
  it has taken effect.

In an Autonomous run, `Autonomous mode: backing off instead of stopping at the crash limit` is
normal too: nobody is there to restart it, so the Watchdog keeps retrying with a growing wait.

Treat a `Status: ESCALATE`, `Status: DONE`, `Status: DONE_PARTIAL`, or `Status: FAILED` line arriving
in the stream, or the process exiting, as the trigger to stop the monitor and move to the matching
step below. Exit code 6 means the run stopped at the quota ceiling — report that and offer to resume
after the reset. Exit code 5 means a budget (iterations or hours) ran out. An Autonomous run prints
`Run Report: <path>` on **every** exit, including budget, quota and crash-limit stops; whenever that
line appears, handle it as step 7b does in addition to the matching step.

## 6. On ESCALATE

`.harness/run/ESCALATION.md` is a **queue**, so expect more than one pending entry — the engine parks
questions and keeps working, and only stops when it runs out of executable work (ADR-007). An entry
is pending when its `Status` is `pending` **and** `.harness/run/DECISIONS.md` has no `## D-00N`
heading for its id yet. Read every pending entry. Do not look for answers inside `ESCALATION.md`:
its `### Decision` section is a pointer, never filled in (ADR-025).

Open the batch with a heading that names it as a Foreman decision request, not an ordinary
clarifying question — e.g. "Foreman needs a decision (D-001, D-003 pending):", listing every
pending ID. This is the only point at which `ESCALATE` becomes visible to the user; presented as
plain prose it reads identically to Claude pausing to ask something on its own, and the user has no
way to tell an engine-mandated gate from an ordinary question. Keep the same heading, translated
into the conversation's language, on every re-presentation of a still-pending entry.

Present them as a batch, most blocking first — an entry's `Blocks tasks` field tells you how much
work each one is holding up. Offer the engine's own proposed options as choices when they are
discrete (e.g. approve / edit / reject a Definition of Done), or ask openly otherwise. Never tell
the user to open the file themselves. Also read `ISSUES.md` and report any tasks the engine
abandoned, with their failure reasons — the user may want to answer a question differently once
they see what failed.

When the run is Collaborative, add one more choice to the batch: **switch to Autonomous and let
the engine decide the rest** with its own recommendations, recorded as assumptions and reported at
the end. The DoD approval entry is never covered by that choice — in both modes the user approves
what "finished" means (ADR-027) — so if it is pending, ask for it on its own either way.

Once answered: append each decision and its rationale to `.harness/run/DECISIONS.md`, under a
heading naming the entry's id (`## D-001`), exactly as that file's own header instructs. **Never
write into `ESCALATION.md`** — the engine reads answers only from `DECISIONS.md` (ENGINE.md §6.2),
so an answer written anywhere else is silently never consumed and the run escalates again on the
same question. `DECISIONS.md` is provisioned by the runtime; if it is somehow missing, create it
from `.harness/loop/templates/DECISIONS.template.md` first. Answering a subset is fine — unanswered
entries stay queued and their tasks stay blocked. If the user chose to switch, answer only the DoD
approval (if pending) and relaunch with `-Mode Autonomous`.

Then return to step 4 (relaunch, re-attach the monitor). Repeat until the run reaches DONE or
FAILED.

## 7. On DONE

Read the Cleanup Commit message for the branch that just finished (`git log -1 <branch>`) — per
the engine's own contract it already contains what was built, DoD evidence, and notable
amendments.

Then build a **roll-up across every `loop/*` branch** in the repository (`git branch --list
'loop/*'`), not just the one that just finished:

- `DONE` branches → use their Cleanup Commit message directly.
- In-progress or stuck-at-escalation branches → commit history since it diverged from the default
  branch, plus that branch's `.harness/run/STATE.md` / `.harness/run/PLAN.md` for current progress and any pending
  decision.
- Stale/abandoned-looking branches → flag as such rather than guessing at intent.

Present a table: branch → status (DONE / in-progress / escalated-awaiting-decision / abandoned) →
what it contains → merge-ready or not. Then surface `ISSUES.md` for the branch that just finished:
abandoned tasks with their failure reasons, unfixed review findings, and recorded assumptions. A
`DONE` run should have none of the first kind — if it does, something is inconsistent and worth
saying so.

Remind the user that merging is always their manual step — neither this skill nor the engine ever
merges. The engine pushes only the Loop Branch, and only when this repository granted push (ADR-011).

## 7b. The Run Report (Autonomous runs)

An Autonomous run ends with `RUN-REPORT.html` at the repository root, rendered by the runtime from
the engine's ledgers. It is excluded from git, so it never appears in `git status`. Give the user its
path, then summarize it in the conversation from the ledgers it was built from — never ask the user to
open files to find out what happened:

- the outcome and the reason line;
- every assumption in `.harness/run/ASSUMPTIONS.md` (id, the question, what was taken), Tier-3 ones
  first, since each marks DoD criteria that can never make the run `DONE`;
- every entry in `.harness/run/RECOVERY.md` — what was deleted, snapshotted or pushed, and that each
  has a restore command;
- the `human` criteria under "Awaiting a person" in `.harness/ISSUES.md`, as the checklist the user
  can work through now.

Offer two ways forward: overturn any assumption by answering its id (written into
`.harness/run/DECISIONS.md` exactly as step 6 describes, then relaunching), or sign off the
"Awaiting a person" checklist the same way. After a `DONE` the `.harness/run/` ledgers are gone from
the tip; read them from the commit before the Cleanup Commit (`git show <cleanup>^:.harness/run/ASSUMPTIONS.md`).

## 8. On FAILED

Stop. Report `.harness/run/STATE.md`'s last recorded findings for that branch, plus `ISSUES.md` if it
exists. Do not attempt a roll-up.

## 9. A run that ends incomplete

A Collaborative run with abandoned tasks reports `ESCALATE`, never `DONE`, and never runs the
Verifier — an incomplete feature is not verified, by design. An Autonomous run reports `DONE_PARTIAL`
instead (exit 7): it did run the Verifier over the `machine` criteria, but it is just as incomplete,
and step 7b's report is the primary artifact. `.harness/run/` therefore survives on the branch (no Cleanup
Commit ran), so the full failure detail is still there. Report `ISSUES.md` as the primary artifact
and be explicit that the feature is **not** complete: say which DoD criteria are unmet rather than
implying the branch is mergeable.
