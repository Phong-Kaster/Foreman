# All loop artifacts live under one `.harness/` directory

The loop previously scattered four things across a consumer repository's root: `.loop/`, `.ai/`, `knowledge/`, and `ISSUES.md`, alongside the human's `PRD.md`. Three of those names are poor neighbours in someone else's codebase — `knowledge/` in particular is an undecorated, extremely generic top-level directory that a real project could plausibly already own — and `.ai/` says nothing about either its content or its lifecycle.

They are now nested under a single dot-prefixed container, with each lifecycle keeping its own subdirectory:

```
.harness/
├── loop/         install-time; replaced only by runtime upgrades   (was .loop/)
├── knowledge/    per repository; cumulative across runs
├── run/          per feature run; disposable                       (was .ai/)
└── ISSUES.md     the Issues Report; survives the Cleanup Commit
PRD.md            human-authored intent; stays at the root
```

**This does not violate the lifecycle rule it appears to.** `architecture.md` §3 requires that artifacts with different lifecycles never share a folder *whose primary operation is folder-level* (copy to install, delete to reset). Nesting them as siblings under a common parent preserves that exactly: install still copies `.harness/loop/`, resetting a run still deletes `.harness/run/`, the Cleanup Commit still removes `.harness/run/` and nothing else, and `knowledge/` still survives every run because it was never inside `run/`. The parent is a namespace, not a unit of operation.

`.ai/` is renamed to `run/` in the process: the old name described neither its content nor its disposability, and the reorganization made a better name free.

## Considered Options

- **Leave the layout as it was** — rejected: the cost is borne entirely by the consumer repository, which is not this project's to spend. `knowledge/` alone is a realistic collision.
- **`harness/` without the dot** — rejected. "Harness" is common vocabulary in testing, so an undecorated `harness/` is exactly the collision risk `knowledge/` already demonstrates. The dot also keeps it out of most editor trees by default, which is the point of the change.
- **Move `PRD.md` in too, for full consistency** — rejected, on the ownership line rather than on taste. Everything under `.harness/` is either the product's, the engine's, or engine-generated; `PRD.md` is the only artifact a human authors from nothing. Mixing the human's input into a directory of machine artifacts blurs precisely the plane boundary `architecture.md` §2 is built on, and in the manual path it also buries the one file the human must create.
- **Keep `ISSUES.md` at the root for visibility** — considered and reversed by explicit decision. Its purpose (ADR-010) is to be *found* after an unattended run, which argued for the root; grouping every loop artifact in one predictable place argued for `.harness/`. The latter won: one known directory to look in is not less discoverable than one more file among a project's root clutter.
- **Introduce a separate `state/` directory** — rejected as redundant: `run/` already *is* the run's state (`STATE.md`, `RESUME.md`, `TASKS/`, `HISTORY.md` all live there). A third directory would split one lifecycle across two folders, which is the very thing §3 warns about.

## Consequences

- **Breaking change for existing installs.** A consumer repository already carrying `.loop/`, `.ai/`, and `knowledge/` must move them (`.loop/` → `.harness/loop/`, `.ai/` → `.harness/run/`, `knowledge/` → `.harness/knowledge/`) or reinstall. There is no automatic migration and none is planned: the Skill re-materializes `.harness/loop/` on every invocation, so in practice the only manual moves are `knowledge/` (worth keeping) and `.ai/` (only if a run is mid-flight).
- The Runtime's deny rules move with the paths (`.harness/loop/**`, `.harness/knowledge/capabilities.json`, `.harness/run/capabilities.json`); the enforcement surface is unchanged in substance.
- `.claude/agents/` **cannot** join the container. Claude Code discovers agent definitions only from `.claude/agents/`, verified in practice — so the materialization target stays where the platform requires. That directory belongs to the CLI rather than to this loop, so it is not clutter this ADR is responsible for.
- Path literals in the runtime use nested `Join-Path` rather than an embedded separator. This is not stylistic: embedding a separator in a generated literal is how a stray control character once entered a path and silently created a misnamed directory.
- `$AiDir` is renamed `$RunDir` in the runtime, so no identifier still claims the old name.
