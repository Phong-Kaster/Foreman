---
name: foreman
description: Start or resume the Foreman engine in this repo, from inline requirement text or a path to a requirement document. Supervises the run live, handles ESCALATE gates as normal conversation instead of manual file edits, and reports a roll-up summary of all loop branches when done.
disable-model-invocation: true
---

The user's raw input (inline requirement text, OR a path to a requirement document, OR empty) is:

$ARGUMENTS

Follow these steps in order. Do not skip steps or add interpretation beyond what's specified.

## 1. Locate the installed runtime files

Check `.claude/skills/foreman/` and `.agents/skills/foreman/` (identical copies) —
use whichever exists; call it `<SkillDir>` below. It contains `ENGINE.md`, `POLICIES.md`,
`models.json`, `agents/`, `capabilities/baseline.json`, `templates/`, `scripts/run.ps1`.

## 2. Sync .harness/loop/ at the repo root

Copy `<SkillDir>/ENGINE.md`, `POLICIES.md`, `models.json`, `agents/`, `capabilities/`, `templates/`, and
`scripts/run.ps1` (as `.harness/loop/run.ps1`) into `.harness/loop/` at the repository root, overwriting existing
copies there.
Never touch `.harness/run/`, `.harness/knowledge/`, or `PRD.md` — those are per-repo runtime state, not part of
the distributable, and must survive across skill updates untouched.

## 3. Resolve the PRD input

Trim the argument text from $ARGUMENTS above.

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

Tell the user it started, and note the log path it prints
(`%TEMP%\loop-run-<repo-folder-name>.log`).

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

Treat a `Status: ESCALATE`, `Status: DONE`, or `Status: FAILED` line arriving in the stream as the
trigger to stop the monitor and move to the matching step below. Exit code 6 means the run stopped
at the quota ceiling — report that and offer to resume after the reset.

## 6. On ESCALATE

`.harness/run/ESCALATION.md` is a **queue**, so expect more than one pending entry — the engine parks
questions and keeps working, and only stops when it runs out of executable work (ADR-007). Read
every entry whose `## Decision` section is still empty.

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

Once answered: write each decision and its rationale into that entry's `## Decision` section
yourself. Answering a subset is fine — unanswered entries stay queued and their tasks stay
blocked. Then return to step 4 (relaunch, re-attach the monitor). Repeat until the run reaches
DONE or FAILED.

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

Remind the user that merging is always their manual step — this skill and the engine never merge
or push; per the engine's own invariant, that stays a human act.

## 8. On FAILED

Stop. Report `.harness/run/STATE.md`'s last recorded findings for that branch, plus `ISSUES.md` if it
exists. Do not attempt a roll-up.

## 9. A run that ends incomplete

A run with abandoned tasks reports `ESCALATE`, never `DONE`, and never runs the Verifier — an
incomplete feature is not verified, by design. `.harness/run/` therefore survives on the branch (no Cleanup
Commit ran), so the full failure detail is still there. Report `ISSUES.md` as the primary artifact
and be explicit that the feature is **not** complete: say which DoD criteria are unmet rather than
implying the branch is mergeable.
