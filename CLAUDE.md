@.claude/git-commit-message.md
@.claude/distributable-parity.md
@.claude/adr-convention.md
@.claude/field-reports.md
@.claude/guide-parity.md

# Foreman — working notes

Conventions for agents working in **this** repository — the place Foreman is built, not a repository
Foreman is running in. The imports above carry the detail; this file carries what applies everywhere.

## Know which repository you are in

Foreman is a product that installs itself into other repositories, so almost every filename here has
a counterpart that means something different elsewhere. Getting this wrong is the most expensive
mistake available in this repo.

| Path | In **this** repository | In a **consumer** repository |
|---|---|---|
| `.harness/loop/` | **Source.** The distributable, edited by hand. | Disposable. Overwritten by the skill on every `/foreman`. |
| `.harness/knowledge/` | Does not exist. | Per-repo, cumulative, survives runs. |
| `.harness/run/` | Does not exist. | Per-run, deleted at the Cleanup Commit. |
| `.git/foreman-mode` | Does not exist. | The Run Mode (ADR-027), outside the working tree, engine-denied. |
| `PRD.md` | Does not exist. | The human's intent for one run. |
| `CLAUDE.md` | This file. | The consumer's own conventions — **a source, never edited**. |

If a task involves `.harness/run/`, `.harness/knowledge/`, or `PRD.md`, you are almost certainly meant
to be working in a consumer repository, not here. (Before ADR-014 these were `.loop/`, `knowledge/`
and `.ai/`; older ADRs and field reports still use those names.)

## Doctrine is governed by the Ratchet; preferences are not

`.harness/loop/ENGINE.md` and `.harness/loop/POLICIES.md` are injected into every engine invocation as system prompt.
A line there is earned by a **real failure** — a broken build, a failing test, a review finding, a
denied command — and removed once the model no longer needs it (`.harness/loop/POLICIES.md`, ADR-019).

An anticipated problem is not a failure. Before adding doctrine, name the run that broke. If you
cannot, the lesson is not ready and probably belongs in an ADR or a commit body instead.

This file and `.claude/` are **not** ratchet-governed. They are operator preferences and may record
taste, house style, and things that merely would be nicer.

## Verify rather than assert

This repository's own product exists because unverified claims pass review. Hold the repo to the
standard it sells:

- Reproduce a defect before reporting it. Six of the twenty findings in the last field report were
  reproduced end to end; two more were **withdrawn** after re-testing contradicted the first reading.
- Run `Invoke-Pester -Script @{ Path = 'tests/run.Tests.ps1' }` after touching `run.ps1` or the
  fixture. It needs no network, no API calls, and no real `claude` — the `-ClaudeCommand` seam and
  `tests/fixtures/fake-claude.ps1` cover the whole runtime.
- A claim about the permission matcher, the shell, or the CLI is testable in minutes. Test it. The
  engine's own note that `set -o pipefail` was refused turned out to be true *and* to understate the
  problem, which only a test could show (ADR-022).

## Windows is the only supported platform, and it leaks

`run.ps1` is PowerShell 5.1; there is no `run.sh` yet. Two traps have already cost real debugging:

- `[int]` **rounds**, it does not truncate. `[int]$span.TotalHours` renders 36 minutes as `01:36`.
  `run.ps1`'s own `Format-Elapsed` still had it until ADR-027's work; use `[Math]::Floor`.
- Git Bash rewrites `ref:path` into `ref;path` when the ref contains a slash **and** the path starts
  with a dot-directory — i.e. exactly `loop/<slug>` plus `.harness/**`. Resolve the ref with
  `git rev-parse` first, or prefix `MSYS_NO_PATHCONV=1`.

## Lessons from real runs

Each of these cost a real run time or quota. They are here so the next change does not repeat them.

- **A quota reading names its window; never assume `five_hour`.** A `rate_limit_event` carries
  `rateLimitType` and several `unifiedWindows`, and the CLI warns about `seven_day` from 75%. Code
  that applied every warning to the five-hour window slept 2 h 31 min on a warning that a five-hour
  reset could never clear (Calendar-Note, `loop/music-player`, 2026-09-24; ADR-027). Before changing
  anything in the quota path, read the raw events in `%TEMP%\loop-run-<repo>.raw.jsonl`, not the
  summary line — that run's log said `at/above 90%` while no window was above 88%.
- **A rule narrows to what earned it.** The five-hour warning rule was earned by 40% → 100% inside one
  iteration; that evidence says nothing about a window that moves over seven days. When widening or
  reusing a guard, re-read the failure that earned it and check the new case matches it.
- **Autonomous mode turns silent waits into lost hours.** A wrong stop or sleep that a person would
  notice in minutes goes unnoticed until the Run Report. Every path that waits must name what it is
  waiting for, and must never wait past a budget it will then stop on.
- **Test the fixture against the field event, not a tidy one.** The fake-claude `WARNED` directive
  always said `five_hour`, so the suite could not see the bug. When a real event breaks something,
  add it to the fixture verbatim (`WARNED7`) before fixing.

## Never commit or push unless asked

The engine never merges and never touches the default branch — an invariant of the product
(ADR-003). It pushes only the Loop Branch, and only where a repository granted push (ADR-011). Hold
yourself to the stricter rule when working here: never commit or push unless asked; leave changes in
the working tree and say so.
