---
name: foreman
description: Start or resume the Foreman autonomous engine in this repo, from inline requirement text or a path to a requirement document. Supervises the run live, handles ESCALATE gates as normal conversation instead of manual file edits, and reports a roll-up summary of all loop branches when done.
disable-model-invocation: true
---

The user's raw input (inline requirement text, OR a path to a requirement document, OR empty) is:

$ARGUMENTS

Follow these steps in order. Do not skip steps or add interpretation beyond what's specified.

## 1. Locate the installed runtime files

Check `.claude/skills/foreman/` and `.agents/skills/foreman/` (identical copies) —
use whichever exists; call it `<SkillDir>` below. It contains `ENGINE.md`, `POLICIES.md`,
`capabilities/baseline.json`, `templates/`, `scripts/run.ps1`.

## 2. Sync .loop/ at the repo root

Copy `<SkillDir>/ENGINE.md`, `POLICIES.md`, `capabilities/`, `templates/`, and `scripts/run.ps1`
(as `.loop/run.ps1`) into `.loop/` at the repository root, overwriting existing copies there.
Never touch `.ai/`, `knowledge/`, or `PRD.md` — those are per-repo runtime state, not part of
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

- Document-path case: `powershell -File .loop/run.ps1 -PrdPath "<resolved path from step 3>"`
- Inline-text / existing-PRD.md case: `powershell -File .loop/run.ps1`

Tell the user it started, and note the log path it prints
(`%TEMP%\loop-run-<repo-folder-name>.log`).

## 5. Supervise live

Immediately attach a Monitor to the same log file (`tail -f` on the path from step 4), unfiltered,
with `persistent: true` — a run can take a long time. Every line `run.ps1` writes (iteration
headers, `engine>` tool-use lines, `engine:` text snippets, `Status:` lines) now streams into the
conversation live, the same as any other command's output.

While watching, keep a running note of anything the engine records as a discovery classified
"no action" / noted-but-not-acted-on (visible in the stream or in `.ai/STATE.md` history) — these
otherwise vanish when `.ai/` is deleted at completion, and belong in the final summary (step 7).

Treat a `Status: ESCALATE`, `Status: DONE`, or `Status: FAILED` line arriving in the stream as the
trigger to stop the monitor and move to the matching step below.

## 6. On ESCALATE

Read `.ai/ESCALATION.md` (question, context, options considered, recommendation, any proposed
capabilities). Ask the user directly in conversation, as a normal question — offer the engine's
own proposed options as choices when they are discrete (e.g. approve / edit / reject a Definition
of Done), or ask openly otherwise. Never tell the user to open the file themselves.

Once answered: write the user's decision and rationale into `.ai/ESCALATION.md`'s `## Decision`
section yourself. Then return to step 4 (relaunch, re-attach the monitor). Repeat until the run
reaches DONE or FAILED.

## 7. On DONE

Read the Cleanup Commit message for the branch that just finished (`git log -1 <branch>`) — per
the engine's own contract it already contains what was built, DoD evidence, and notable
amendments.

Then build a **roll-up across every `loop/*` branch** in the repository (`git branch --list
'loop/*'`), not just the one that just finished:

- `DONE` branches → use their Cleanup Commit message directly.
- In-progress or stuck-at-escalation branches → commit history since it diverged from the default
  branch, plus that branch's `.ai/STATE.md` / `.ai/PLAN.md` for current progress and any pending
  decision.
- Stale/abandoned-looking branches → flag as such rather than guessing at intent.

Present a table: branch → status (DONE / in-progress / escalated-awaiting-decision / abandoned) →
what it contains → merge-ready or not. Fold in the "no action" / noted-but-not-archived items
gathered in step 5 for the branch that just finished.

Remind the user that merging is always their manual step — this skill and the engine never merge
or push; per the engine's own invariant, that stays a human act.

## 8. On FAILED

Stop. Report `.ai/STATE.md`'s last recorded findings for that branch. Do not attempt a roll-up.
