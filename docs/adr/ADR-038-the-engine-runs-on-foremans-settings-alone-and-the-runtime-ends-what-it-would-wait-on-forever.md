# The engine runs on Foreman's settings alone, and the Runtime ends what it would otherwise wait on forever

ADR-037 closed what Kanso's first three runs broke and named five things it had not solved. This
ADR closes them. Each was measured first, on Claude Code 2.1.292, on 2026-10-08.

- **The operator's configuration still reached the engine.** By default the engine loaded six of the
  person's plugins (four installed, two synced from their account). It loaded 92 skills and 127 slash
  commands, and ran their SessionStart hook, which injects a personal formatting ruleset into every
  invocation. The person's settings also chose the engine's effort level: `effortLevel: xhigh` came
  from there.
- **A git that printed an error still ended the Runtime.** ADR-037 wrapped one call. The others were
  still exposed. An `origin/HEAD` pointing at a remote branch that is not there made
  `git rev-list --count origin/main..HEAD` print an error. Windows PowerShell 5.1 turns that stderr
  into a terminating error under `ErrorActionPreference Stop`, and `run.ps1` exited 1 before the
  first iteration.
- **The checklist guard counted, so a swap passed.** An iteration that removed `Run 1 12` and added
  an unrelated item left the count unchanged.
- **The time bound on tests was doctrine only.** Nothing in the Runtime stopped a test JVM that never
  finished while the engine kept polling it.
- **A WMI-launched run surviving the app closing was only reasoned**, from its parent process.

## The decision

**The engine reads no user-level settings.** `run.ps1` passes `--setting-sources project,local`.
Measured with and without it:

| | Default | `project,local` |
|---|---|---|
| Plugins | 10 (the operator's 6, plus 4 built in) | 4 built in |
| Skills | 92 | 22 |
| Slash commands | 127 | 57 |
| SessionStart hook | yes | none |

The login, the deny rules from the compiled `--settings`, and what `sonnet` and `opus` resolve to
(`claude-sonnet-5-5`, `claude-opus-5-5`) did not change. Two things the user layer used to supply now
come from Foreman:

- Each tier in `models.json` names its effort level, passed as `--effort`. Both tiers are `xhigh`,
  the level every run so far actually ran at.
- `run.ps1` sets `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` for the engine. The operator had it set; left
  on, the engine could carry notes from one invocation to the next outside the repository, and
  iterations are stateless (ADR-001).

**Every git call goes through one function.** A `git` function at the top of `run.ps1` takes
precedence over `git.exe`. Inside it, `ErrorActionPreference` is `Continue`, so stderr is only a
stream again: the caller's `2>$null` still discards it, and the caller still reads `$LASTEXITCODE`.
On the dangling-`origin/HEAD` repository, the old runtime exits 1 at startup and the new one runs to
`DONE`.

**An unsigned item with an id must survive.** The guard reads the id an item opens with (`Run 1 12`,
`5`, `Run 3 7`). After an iteration, every open id must still be there, open or ticked, as well as
the count holding. Rewording that keeps the id passes; a swap stops the run.

**The Runtime ends a hung test of its own repository.** While the engine runs, every 30 seconds,
`run.ps1` looks for Gradle test workers. A worker qualifies only if its
`-Dorg.gradle.internal.worker.tmpdir` lies under this repository and under a test task's `build/tmp`.
It ends any older than `-MaxTestWorkerMinutes` (30). The build then fails and names the test, which
is what the operator did by hand on 2026-10-07.

Checked against the real Kanso test worker's command line, and against three that must not match:

- Kanso's compile worker;
- another project's test worker;
- a sibling folder, `Kanso-old`.

Only the first matched.

**A WMI-launched run is outside the app's job.** Measured with `IsProcessInJob`:

- this session's own process: in a job;
- a child it starts with `Start-Process`: in a job;
- a process WMI creates (parent `WmiPrvSE`): not in any job.

The app kills its job when it closes, which is how Run 3 died at 12:31. So `/foreman` step 4's
launch is now measured, not assumed.

## Considered Options

- **Pointing the engine at a private `CLAUDE_CONFIG_DIR`**: rejected. That directory also holds the
  login, so it would need credentials copied into a second place.
- **`--bare`**: rejected again, for ADR-037's reasons: it reads no OAuth login and skips `CLAUDE.md`.
- **Wrapping each git call in `try`/`catch`**: rejected. There are twenty call sites, and a new one
  would be unprotected by default. One function covers them all, and future ones.
- **Leaving effort to the CLI default**: rejected. It would silently change every run's reasoning
  effort, and its cost, the day the user layer stopped being read.
- **Ending every long-lived JVM, or every process of the repository**: rejected. Gradle keeps compile
  and worker daemons alive across builds on purpose, and another project's JVM is never this run's to
  end. The match needs both this repository's path and a test task's work directory.
- **Detecting a polling engine** (the same command repeated): rejected. Run 3's polls differed in
  their loop bounds from one call to the next. The hung JVM is the thing to end, and it can be
  identified exactly.

## Consequences

- An engine's behaviour no longer depends on whose machine it runs on, apart from personal memory
  (below).
- Effort is a line in `models.json`, which a person can change per tier.
- A test that hangs fails the build within `-MaxTestWorkerMinutes`, wherever the engine is waiting.
- **Not solved:** the operator's personal `~/.claude/CLAUDE.md` still reaches the engine. Measured: with
  `--setting-sources project,local` the engine still quoted the operator's rule about another
  project. Memory is not a setting source, and no flag short of `--bare` skips it.
- **Not solved:** an item without an id is still only counted.
- **Not solved:** nothing survives a reboot. Run 3 met one at 14:25 on 2026-10-07.
- **Open:** whether 30 minutes is the right bound for a test worker in a repository with a genuinely
  long suite. A suite that runs longer has to raise `-MaxTestWorkerMinutes`.
