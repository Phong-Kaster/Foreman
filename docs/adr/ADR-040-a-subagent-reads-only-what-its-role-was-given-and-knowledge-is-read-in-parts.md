# A subagent reads only what its role was given, enforced by a hook, and knowledge is read in parts

ADR-039 told Workers to read narrowly. The same day's measurements showed why an instruction alone would
not hold, and that the cost had a second source the instruction did not touch.

Counted from the raw stream of Kanso Run 7's last five iterations (2026-10-13, sessions `3102c222` to
`db81af37`):

- The orchestrator mostly did what `ENGINE.md` §6.3 already asked. It read `RESUME.md` first and reached
  into `DoD.md`, `PLAN.md` and `PROJECT.md` with `grep` and `sed` on a few lines. That part of the design
  works.
- **The subagents did not.** Workers and Reviewers opened `DoD.md` whole 15 times and `PROJECT.md` 9 times,
  although the Worker Brief already carried every Constraint and the Reviewer's prompt the criteria it
  needed. The T-003 Worker read `DoD.md` three times and `PROJECT.md` whole before writing a line, and the
  43 KB `api-digest.md` three times for one section. Every token a context reads is re-sent on every later
  call it makes (ADR-039).
- **Two files grow every run, and every run reads them again.** Kanso's `.harness/knowledge/PROJECT.md`
  reached 72 KB by Run 7: 17 KB of Constraints and 55 KB of Reference. Its `.harness/ISSUES.md` reached
  49 KB, of which 43 KB were sections about Runs 3–6. Nothing ever left either file.

The human asked for subagents never to read unexpected files again. Foreman's own rule is that a rule
enforced by a script is a rule, and a rule living only in a prompt is a wish (ADR-002), so this ADR makes
it a script.

## The decision

### A read guard, measured before it was built

Every Read, Grep and Glob passes `bin/foreman-read-guard.ps1`, a `PreToolUse` hook that `run.ps1` adds to
the engine's compiled `--settings`. Three facts it depends on were measured on Claude Code 2.1.296 in a
throwaway repository before any of it was written:

- a hook from `--settings` runs under `--setting-sources project,local`, as the engine is launched;
- a subagent's call carries `agent_type` (`loop-worker`, or `probe-worker` in the probe); the main
  engine's own calls carry none;
- exit 2 refuses the call and hands stderr to the subagent; a hook may instead return `updatedInput`
  without a permission decision, and the call then runs rewritten under the same permission rules.

The guard leaves the main engine alone; `ENGINE.md` and its permission rules govern it. A subagent may
read the repository's code freely and, under `.harness/`, only what its role needs:

| Role | May open under `.harness/` |
|---|---|
| `loop-worker` | `knowledge/reference/**`, `knowledge/DOMAIN.md` |
| `loop-reviewer` | the Worker's set, `run/evidence/**`, `loop/POLICIES.md` |
| `loop-analyst` (bootstrap) | everything except `archive/` |
| anything else | the Worker's set |

The last row matters: an engine that found its Workers refused could dispatch a `general-purpose` agent
instead, and a guard keyed on a list of known names would let it through.

A refusal says where the information lives ("The DoD criteria your task cites are quoted in your Brief"),
so a refused Worker is pointed back at its Brief rather than left to search.

**A repository-wide Grep is rewritten, not refused.** The probe found the gap a path check cannot see: a
Worker's Grep with no path printed matching lines of `DoD.md`, `PROJECT.md` and the archive. The guard
now adds `!.harness/**` to the Grep's glob. Measured: the exclusion works alone and after a comma beside
the Worker's own glob (`*.md,!.harness/**` keeps `*.md` and drops `.harness/`). A Grep whose path is inside
an allowed directory, such as `knowledge/reference`, is left as it is.

The hook costs about 330 ms per Read, Grep or Glob, the main engine's included, measured with five runs
of each. An iteration of about 150 such calls pays roughly 50 seconds. A hook declared in each agent's
frontmatter would spare the main engine, and was rejected because it covers only the agents that declare
it: the generic agent above would carry none.

### What each context is given instead

- **The Worker Brief** carries the quoted DoD criteria (ADR-039), the paths of the reference topics the
  task touches, and every open `ISSUES.md` item naming a file in its scope.
- **The Reviewer's prompt** carries the quoted criteria **and the DoD's Removals section**, which
  `loop-reviewer.md` needs to rate a leftover CRITICAL, plus the Constraints, the topic paths, the diff's
  path under `run/evidence/`, and the evidence paths. It reads `POLICIES.md` by section for the standards.
- **`RESUME.md`** now also quotes the criteria the next Phase cites, the open issues touching its files,
  and its reference topics. The next Iteration writes its Briefs from `RESUME.md` and opens `DoD.md` only
  to Grep a criterion that is missing there. This finishes what §6.3 began: §6.3 already said "`DoD.md`
  only if you are the Verifier", but ADR-039 made every Brief quote criteria, and nothing said where a
  non-Verifier Iteration was to find their text.

### Knowledge is laid out to be read in parts

`PROJECT.md` keeps the Constraints, which go verbatim into every Brief and so are read every time anyway,
the verified commands, and a **Reference index**: one line per topic file under
`.harness/knowledge/reference/`, naming what it covers and when to read it. Reference moves into those
topic files, named by what a task touches and kept under 12 KB each (`POLICIES.md`, Knowledge Layout).

An Iteration on this runtime that finds Reference still in `PROJECT.md`, or a topic file such as Kanso's
`api-digest.md` directly under `knowledge/`, moves it into `reference/` before dispatching anything. It has
to: the guard allows a Worker `reference/` and `DOMAIN.md` only, so Reference left anywhere else is
invisible to the Workers it was written for. The migration therefore costs one Iteration's work in each
existing consumer, once.

### Settled history leaves `ISSUES.md`

A section of `.harness/ISSUES.md` about an earlier run moves to a new file
`.harness/archive/ISSUES-run-<n>.md`, written once and never edited. Only settled content moves: every
open `- [ ]` item is first carried, word for word with its id, into **Awaiting a person**. This needed no
new code: the checklist guard (ADR-037, ADR-038) already stops a run whose Iteration drops an open item,
and an item moved into the archive is exactly that. No context reads the archive: the guard refuses it to
every subagent, and a permission rule denies the main engine `Read(.harness/archive/**)` and
`Edit(.harness/archive/**)`. Writing a new file needs no read.

**Decided by the human, 2026-10-13:** both changes, with the instruction "ensure subagents never read
unexpected files any more".

**What would change this.** If Workers start failing because a Brief left out what they needed and the
guard kept them from finding it, the fix is a better Brief, not a looser guard. Revisit the guard only if
that failure repeats after the Briefs have been corrected. If the 330 ms per call becomes a measurable
share of an iteration's wall clock, move the guard to a faster host than a PowerShell process per call.

## Considered Options

- **Instruction only, in `loop-worker.md` and the Brief** — rejected. ADR-039 had just added that
  instruction, and the T-003 Worker's own reads are the evidence of what an instruction is worth against a
  model looking for context. The human asked for "never".
- **Permission deny rules such as `Read(.harness/run/DoD.md)`** — rejected. Permission rules apply to the
  whole session, the main engine included, and the Verifier must read `DoD.md`. They cannot tell a Worker
  from the orchestrator; the hook can.
- **A hook declared in each agent's frontmatter** — rejected, and the closest call. It would spare the
  main engine 50 seconds per iteration, but it covers only the agents that declare it, and a generic agent
  would read anything.
- **Refusing every repository-wide Grep** — rejected. Workers search the code that way constantly; the
  rewrite keeps the search and drops only `.harness/`.
- **An `.ignore` file for ripgrep** — rejected. It would hide `.harness/` from the main engine's Grep too,
  silently, including the directories it must search.
- **Moving Constraints into topic files as well** — rejected. Every Brief carries all of them by design
  (ADR-016), so splitting them saves nothing and makes them easier to miss.
- **Trimming `ISSUES.md` in place, deleting settled sections** — rejected. They are a person's record of
  why a run ended where it did; the archive keeps them, outside every context.

## Consequences

- A subagent can no longer re-read `DoD.md`, `PROJECT.md`, `PLAN.md`, `ISSUES.md` or the task files. What it
  needs has to be in its Brief or prompt, and the orchestrator is now responsible for putting it there.
- The cost of the knowledge files stops growing with the number of runs: Reference is read by topic, and
  earlier runs' issues leave the file every Iteration reads.
- Every Read, Grep and Glob costs about 330 ms more.
- Pester covers the guard's decision for each role and path form (Windows, relative, mixed case), the
  Grep rewrite, the fallback on unreadable input, and the wiring and archive deny in both Run Modes.
- **Not solved:** a Glob outside `.harness/` still lists file names inside it. Names only; reading any of
  them is refused.
- **Not solved:** the main engine can still read anything outside the archive. Its reads are governed by
  `ENGINE.md` §6.3, which the measurement above shows it mostly follows. The guard does not prove that.
- **Not solved:** the guard checks paths, not tools it does not see. A subagent given Bash could `cat` a
  file; none of the three loop agents has Bash, and the generic agent the guard defends against might.
- **Not solved:** `ENGINE.md` and `POLICIES.md`, about 22K tokens of system prompt, are still re-sent on
  every orchestrator call whatever stage the Iteration is in.
- **Open:** whether the migration of an existing `PROJECT.md` into topic files is done well by the engine
  unaided. Kanso is the first consumer to go through it, and its first Iteration on this runtime is the
  measurement.

## Field results: Kanso, Run 8 (2026-10-14)

Kanso's Run 8 ran on this runtime from bootstrap to `DONE_PARTIAL`: 10 iterations, 2 h 39 min of engine
time, $32.35. Run 7, before this ADR, took 17 iterations and $104. The work and the model mix were
different, so the drop is not a measurement of the guard; it is only the first data point. Read from
the run's raw stream (`%TEMP%\loop-run-Kanso.raw.jsonl`, 14 MB) and the repository:

- **The knowledge split held.** Kanso's `PROJECT.md` went from 72 KB to 30 KB. Its Reference now lives in
  15 topic files under `.harness/knowledge/reference/`, and the engine made the move unaided in `c1717d4`.
  That answers the **Open** item above for one consumer.
- **The guard refused two calls in the whole run.** That is two refusals, against the 24 whole-file
  reads of `DoD.md` and `PROJECT.md` that Run 7 made in five iterations. Both refusals show the guard
  disagreeing with this ADR, not a subagent straying:
  - *A bootstrap analyst was refused `.harness` itself:* `loop-analyst may not read .harness`. The table
    above gives the analyst "everything except `archive/`", but `bin/foreman-read-guard.ps1` allows the
    analyst only `.harness/*`, which does not match the directory `.harness` itself. A Grep or Glob aimed
    at the folder is refused.
  - *A Worker was refused a file its own task owned:* `loop-worker may not read
    .harness/run/evidence/readme-paths.sh`. T-008's Declared File Scope named that script, so the Worker
    was told to edit a file the guard would not let it read. A task whose scope reaches into
    `.harness/run/evidence/` cannot be done by a Worker under the Worker's set.
- **Nothing moved to the archive.** Kanso's `.harness/ISSUES.md` is now 65 KB. It still holds the settled
  sections of Runs 3–7, beside the `ISSUES-run-1-6.md` a person had copied out, and it has a second "Run 8"
  section at its end. No Iteration of Run 8 applied "a settled earlier run leaves the file for the
  archive", so the cost this ADR removed from `PROJECT.md` is still being paid in `ISSUES.md`.

The whole run is written up in [the Run 8 field trial](../field-trial-2026-10-14-kanso-run-8.md).

**Not solved by this section, recorded so it is not lost:** the analyst's row and the Worker's evidence
scope need a change to the guard and its tests. The archive step is either unclear in `POLICIES.md` or is
not reached by an Iteration that has work to do; that needs a reading of Run 8's iterations, not a guess.
