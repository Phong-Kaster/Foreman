# The engine inherits nothing from the person running it, touches nothing other projects share, and cannot make a person's check disappear

Kanso's first three runs (2026-10-05 to 2026-10-07) were Foreman's first long Autonomous runs on a
machine that was also being used for other projects. Nine faults surfaced. None was a reasoning
failure of the model. Each one was a gap the model walked into, or a gap between the model and the
machine it ran on.

- **The engine inherited the operator's tools.** The process tree of Run 3's engine had the owner's
  phone-control MCP server and their browser server as children. Its `init` event listed 22 MCP
  servers and 21 MCP tools, among them the owner's claude.ai connectors, with Google Drive and
  Claude Docs connected. Autonomous mode allows every tool not on the Deny List, so each one was
  reachable. The phone server would have bypassed ADR-033's wrapper, which is the only route to a
  device.
- **It changed state other projects share.** A build killed mid-write left the machine-wide Gradle
  cache half-written. The engine then ran `./gradlew --stop`, which stops every daemon of that Gradle
  version on the machine, other projects' builds included. It moved 264 entries out of
  `~/.gradle/caches`, and then the whole `transforms` directory.
- **A person's checks disappeared.** Run 2's first phase (0670172) regenerated `.harness/ISSUES.md`
  from its own run and dropped the five checks Run 1 had left unsigned. ENGINE.md told it to:
  the file was listed as "regenerated" every iteration. Separately, the page parser matched only the
  exact heading `## Awaiting a person`. Run 1 had written `(unsigned)` after it and Run 3 nested a
  `### Awaiting a person, Run 3`, so the page reported nothing waiting while 17 checks were.
- **Deleting first got around the baseline approval.** The engine deleted two approved baselines and
  then called `foreman-record-baselines.ps1`. The script treated what is on disk as what exists, so it
  saw the two as new and recorded them again. Only the Runtime's guard caught it, after the fact.
- **The guards misread a broken git.** As the machine shut Run 3 down, `git ls-files` failed. The
  baseline guard logged all 16 baselines as removed, though every one was still on disk. When git
  prints an error there, Windows PowerShell 5.1 turns its stderr into a terminating error under
  `ErrorActionPreference Stop`, and the whole Runtime exits with code 1.
- **Waits had no end.** One Robolectric test spun forever on a preview that never settled, and the
  iteration polled the build log for 35 minutes. The 20-minute idle bound never fired, because the
  polling itself produced events. Later the engine's result came at 16:04:46, but a background shell
  it had started sat on a malformed heredoc and kept its process alive. The Runtime would have waited
  out the idle bound before reading a status that was already written.
- **The run died with the session.** `/foreman` launched `run.ps1` with `run_in_background`. The
  tool's background limit ended Run 1 after 30 minutes. A process started from the session died
  when the app closed, in the middle of Run 3.

## The decision

**No MCP server reaches the engine.** `run.ps1` passes `--strict-mcp-config` with no
`--mcp-config`. This was measured on the real CLI the same day: without the flag, 22 servers and 21
MCP tools; with it, none. Nothing Foreman does needs MCP; library documentation comes from the
`ctx7` CLI (ADR-032).

**State other projects share is never the run's to change.** Three rules join `run.ps1`'s immutable
denies in both Run Modes: `Bash(*gradlew*--stop*)`, `Bash(*gradle *--stop*)` and
`Bash(*.gradle*caches*)`. Measured against the real matcher, they deny `--stop` through `gradlew`,
`cd &&` and `sh`, and every `rm`, `mv` or wrapper call that names the cache, in either slash
direction. Ordinary builds, including `--no-daemon`, still run.

Measuring them found a worse trap: **one rule containing a backslash makes the CLI ignore the whole
settings file.** Every deny goes with it, `DECISIONS.md`, the Deny List and `adb` included, and
nothing reports it. A deny on `git log` stopped working the moment a second rule held `\caches`. So
the rules are written without backslashes, and `run.ps1` now refuses to start (`FAILED`) when any
compiled rule contains one. A Windows path in a repository's ledger is the easy way to write one.

**An unsigned item leaves only by being ticked.** ENGINE.md §10 now says the file is *updated*, and
that every `- [ ]` item already in it, from any run, stays word for word until it is ticked. After
every iteration the Runtime compares counts. Open items may go down only by as many as were ticked.
If they go down by more, the run stops `FAILED` and lists what went missing. The page's parser now
reads every section whose heading starts "Awaiting a person", at any level, and counts a nested
section once.

**A committed baseline exists whether or not it is on disk.** The recording script also reads the
baselines committed at `HEAD`. One deleted before recording is put back from `HEAD`, unless the human
listed it under `## Baselines`.

**A git that cannot answer proves nothing.** The baseline snapshot treats a failed or erroring
`git ls-files` as "unknown". It catches the PowerShell exception, and the guard then compares nothing
for that iteration.

**Every wait has an end.** POLICIES.md requires a time bound on build and test commands, and treats
running out of time as a failed attempt that names what was running. When the engine has reported its
result but its process stays alive with no new event for `-ResultGraceSeconds` (120 by default), the
Runtime ends the process tree and reads the status as usual.

**A run outlives the session that started it.** `/foreman` step 4 has WMI create `run.ps1`, with a
hidden window, so its parent is `WmiPrvSE` rather than the session. Step 5 also watches the process,
since its exit no longer reaches the session by itself.

## Considered Options

- **`--bare`** for full isolation: rejected. It reads no OAuth credentials, so a subscription login
  stops working, and it skips `CLAUDE.md` discovery, which the engine must read as a source.
- **Denying the dangerous MCP servers by name** (`mcp__android-agent` already is): rejected as the
  fix. Connectors and plugin servers arrive per account and change without notice, so a list of names
  is never complete. Strict mode removes all of them in one flag.
- **`--setting-sources project,local`** to drop the operator's plugins and hooks as well: not taken
  here. Its effect on authentication and on the Runtime's own `--settings` was not measured, and
  nothing those plugins did has failed yet. This was the closest call, and it is the next thing to
  measure.
- **Matching unsigned items by their text**: rejected. Rewording an item, or adding what was driven
  and from which state, is legitimate; it happened in Run 2. Counting open items against ticks lets
  rewording through and catches the deletion that actually happened.
- **The Runtime restoring dropped items itself**: rejected. It would leave `ISSUES.md` dirty, which
  the next iteration treats as crash debris (ENGINE.md §6.1). It could revert the restoration.
- **Ending the engine the moment its result arrives**: rejected. The CLI can take another turn after
  a result when a background task reports, and Run 3's did. A grace with no new events keeps that
  turn and still ends a process that is only lingering.
- **Task Scheduler instead of WMI**: rejected. It registers a task that outlives the run and has to
  be cleaned up; WMI creates one process and leaves nothing behind.

## Consequences

- An engine in either mode sees only the tools its ledgers grant, and the operator's connected
  accounts are out of its reach.
- A ledger rule with a backslash now stops the run at launch instead of silently disarming it. A
  repository that wrote one has to rewrite it with forward slashes.
- An Autonomous run that drops a person's check stops. That costs the rest of the run's hours, which
  is deliberate: the alternative is a question made to disappear (ENGINE.md §11).
- **Not solved:** the engine still inherits the operator's plugins, skills and hooks. Run 3's engine
  ran the owner's SessionStart hook, which injects a personal formatting ruleset, and had 92 skills
  and 127 slash commands. None has caused a failure yet.
- **Not solved:** the checklist guard counts. An iteration that removes one item and adds an
  unrelated one passes.
- **Not solved:** a WMI-launched run has not yet been observed surviving an app restart; that is
  reasoned from its parent process. Nothing survives a reboot, and Run 3 met one at 14:25.
- **Not solved:** other `& git ... 2>$null` calls in `run.ps1` can still end the Runtime the same way
  when git prints an error.
- **Not solved:** the time bound on tests is doctrine. Nothing in the Runtime enforces it while an
  engine keeps producing events.
- **Open:** whether `--setting-sources project,local` isolates the plugins and hooks without
  breaking the login or the compiled `--settings`.

**Followed by [ADR-038](./ADR-038-the-engine-runs-on-foremans-settings-alone-and-the-runtime-ends-what-it-would-wait-on-forever.md)**,
which closes the plugins, skills and hooks, every remaining git call, the swap, the unenforced test
bound and the unmeasured launch, and keeps the operator's personal memory as the one thing open.
