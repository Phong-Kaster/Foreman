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
| `.loop/` | **Source.** The distributable, edited by hand. | Disposable. Overwritten by the skill on every `/foreman`. |
| `knowledge/` | Does not exist. | Per-repo, cumulative, survives runs. |
| `.ai/` | Does not exist. | Per-run, deleted at the Cleanup Commit. |
| `PRD.md` | Does not exist. | The human's intent for one run. |
| `CLAUDE.md` | This file. | The consumer's own conventions — **a source, never edited**. |

If a task involves `.ai/`, `knowledge/`, or `PRD.md`, you are almost certainly meant to be working in
a consumer repository, not here.

## Doctrine is governed by the Ratchet; preferences are not

`.loop/ENGINE.md` and `.loop/POLICIES.md` are injected into every engine invocation as system prompt.
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

- `[int]` **rounds**, it does not truncate. `[int]$span.TotalHours` renders 30 minutes as `01:…`.
- Git Bash rewrites `ref:path` into `ref;path` when the ref contains a slash **and** the path starts
  with a dot-directory — i.e. exactly `loop/<slug>` plus `.ai/**`. Resolve the ref with
  `git rev-parse` first, or prefix `MSYS_NO_PATHCONV=1`.

## Never commit or push unless asked

The engine never pushes and never merges — that is an invariant of the product (ADR-003). Hold
yourself to the same rule when working here: leave changes in the working tree and say so.
