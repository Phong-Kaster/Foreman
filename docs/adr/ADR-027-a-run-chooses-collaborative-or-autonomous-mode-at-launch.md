# A run chooses Collaborative or Autonomous mode at launch; the engine can never choose it for itself

> **Status: implemented, 2026-09-24; not yet proven by a real run.** The switch, `ENGINE.md` §14, the
> Autonomous permission compiler, the Recovery Wrappers, `DONE_PARTIAL`, the budgets and the Run Report
> are all in place and covered by the Pester suite — but only against `fake-claude`. No real engine has
> run an Autonomous run end to end yet, so everything the *engine* is asked to do in §14 is specification,
> not observed behaviour. The first real Autonomous run is this ADR's first real evidence.

Foreman was built around one promise: the DoD approval is "the **only blocking gate** in a run"
(`ENGINE.md` §5). Read against the rest of the specification, that promise holds only for the
*first* stop. A run still returns to the human through five other doors:

1. a Tier-2 decision — architecture, execution strategy, a capability grant — is queued, the tasks it
   names are deferred, and the run reports `ESCALATE` as soon as it runs out of unblocked work
   (`ENGINE.md` §7, §9);
2. a Tier-3 intent conflict between `PRD.md` and the approved DoD blocks nearly everything through
   the dependency graph and escalates within an Iteration or two;
3. a task abandoned after three attempts makes `DONE` unreachable, so the run ends `ESCALATE`
   (`ENGINE.md` §8);
4. a `human` criterion (ADR-015) cannot be signed off by the engine, so `DONE` waits on a person;
5. the Runtime stops outright on the third consecutive crash or at `MaxIterations = 50`
   (`run.ps1`, the Watchdog and the iteration budget, ADR-012, ADR-024).

Each of those doors is correct for a human sitting near the machine. None of them is correct for a
human who wants to hand over a long task in the evening and read one report in the morning. The
human asked for both, and for a switch between them:

**Decided by the human, 2026-09-24:** Foreman gains two modes. **Collaborative** keeps today's
behaviour: important decisions stop for a human, who rules and lets the run continue.
**Autonomous** asks only at launch, decides everything else itself, and reports everything it
decided, and everything it did that could not be undone by `git revert` alone, in one HTML file at
the end of the run.

**What would change this assessment.** An Autonomous run whose recorded assumptions a human later
has to unwind at a cost greater than the Collaborative stops would have cost. That is the failure
this ADR is betting against, and the first one observed should reopen it.

## The switch

`run.ps1` gains `-Mode Collaborative | Autonomous`. A new run — one with no `.harness/run/` yet —
starts **Collaborative** unless `-Mode` says otherwise, so every existing consumer and every existing
test keeps its current behaviour without a flag, and a run never inherits the previous run's mode.
A run already in progress, relaunched without `-Mode`, keeps the mode it had.

The mode lives in `<git-dir>/foreman-mode` (`git rev-parse --absolute-git-dir`), and the permission
compiler denies the engine `Edit` and `Write` on `.git/foreman-mode`. The deny rule is the
`DECISIONS.md` pattern (ADR-025) applied a fourth time, and it is not optional: a mode the engine
could write is a mode the engine could promote itself into, and moving from Collaborative to
Autonomous is exactly the self-granted expansion of authority that `ENGINE.md` Invariant 3 exists to
forbid.

The location is the first draft's correction. It first put the file at `.harness/run/MODE`, beside
`DECISIONS.md`, which fails twice over. Before bootstrap, a `.harness/run/` that exists is how the
engine decides bootstrap already happened (`ENGINE.md` §5), so provisioning the mode there would skip
it. After bootstrap, a file the Skill rewrites mid-run inside the working tree is an uncommitted
change, and `ENGINE.md` §6.1 tells the engine to treat a dirty tree as crash debris and revert it —
it would undo the human's switch. Nothing under the git directory is committed or seen as debris.
The cost is that the mode is per clone, not per branch; two Loop Branches run one after the other in
the same clone share it until the second one bootstraps, which resets it.

`run.ps1` re-reads the file at the start of every Iteration and never writes it again except when
`-Mode` is passed explicitly, so a switch made while an Iteration is running takes effect at the next
one, and each iteration header in the log ends with `| mode <Mode>`.

## Switching from `/foreman`

The Skill is where the human actually drives a run, so the switch has to live there too, in three
forms:

- **At launch:** `/foreman --auto <requirement>` or `/foreman --collab <requirement>`. The flag is
  stripped before the PRD is resolved and becomes `-Mode`. No flag passes no `-Mode`.
- **Mid-run:** `/foreman mode auto` or `/foreman mode collab` rewrites the mode file directly. The
  Skill runs in the human's own session, not under the engine's compiled permissions, which is the
  same standing it already uses to write `DECISIONS.md` on the human's behalf. `/foreman mode` alone
  reports the current mode. With no run in progress the Skill refuses to write the file, because the
  next launch would reset it anyway, and points at `--auto` instead.
- **At an escalation:** when a Collaborative run stops at `ESCALATE`, the Skill offers "switch to
  Autonomous and let the engine decide the rest" beside the pending questions. The DoD approval is
  excluded from that choice and still asked on its own.

Switching has defined effects:

- **Collaborative → Autonomous:** every queued, unanswered Decision is resolved at the next
  Iteration with its own recorded recommendation, and moves into the Assumption Ledger.
- **Autonomous → Collaborative:** nothing is unwound. Assumptions already made stay made and stay in
  the ledger; only *future* Tier-2 and Tier-3 questions queue again.

## What is identical in both modes

The DoD approval gate at launch. The human still approves what "finished" means before any task
exists, and `DoD.md` is still immutable to the engine afterwards. Autonomous mode removes the
*mid-run* stops, not the contract. In Autonomous mode, the same launch gate also carries the three
things only Autonomous mode needs approved: the mode itself, the run budget, and the Deny List.

Fresh-context review (ADR-005), verification (§11), evidence rules (ADR-022), stateless Iterations
(ADR-002), and the Loop Branch's append-only character (ADR-003, ADR-011) are unchanged.

## What Autonomous mode changes

### Tier-2 decisions become recorded assumptions

Where Collaborative mode queues a Decision and defers its tasks, Autonomous mode takes the option
the engine would have recommended, and appends an entry to `.harness/run/ASSUMPTIONS.md`:
the question, the options considered, the option taken and why, the checkpoint commit that first
depends on it, and the command that would revert that dependency. The safety property changes, and
this ADR should say so plainly: Collaborative mode guarantees the engine never builds on an
unanswered question; Autonomous mode guarantees only that every such question is written down,
addressed by commit SHA, and reversible on a local branch nobody has merged.

### Tier-3 intent conflicts are resolved toward the PRD and marked, never hidden

The engine still may not change intent. It takes the reading closest to `PRD.md`'s literal text,
records it as an assumption of Tier 3, and marks every DoD criterion that depends on it as
**assumed**. An assumed criterion can be satisfied by evidence, but it can never make a run `DONE`.

### Capabilities invert: allow everything, deny a list

Collaborative mode keeps the allow-listed Capability Ledgers of ADR-004. Autonomous mode compiles
every tool as allowed (the tool names alone, `Bash`, `Edit`, …) plus a **Deny List**, which ships in
`baseline.json`'s `autonomous` block and which the human accepts by choosing the mode. A repository
extends it with `deny` arrays in `.harness/knowledge/capabilities.json` entries. `run.ps1`'s immutable
deny rules still apply on top, and deny always outranks allow.

Commands that are dangerous but recoverable are denied in their raw form and granted only through a
**Recovery Wrapper** under `.harness/loop/bin/`, which captures what is about to be lost, performs or
permits the action, and appends the captured location and the exact restore command to
`.harness/run/RECOVERY.md`. The wrappers live under `.harness/loop/`, which the engine cannot write, so
it can call them but cannot change what they record.

| Wrapper | Action | It first | Restore |
|---|---|---|---|
| `foreman-trash.ps1` | delete a file or folder, typically outside the repository | copies it to `.harness/trash/<timestamp>/`, then removes it; refuses a drive root, the repository, the git directory and the trash | copy it back |
| `foreman-snapshot.ps1` | overwrite or delete a local database file or data folder | copies it to `.harness/trash/<timestamp>/`; the destructive command is the engine's next step | replace it with the copy |
| `foreman-push.ps1` | push the Loop Branch | refuses anything but `loop/*`; records the remote ref's previous SHA; never `--force` | `push --force-with-lease` the previous SHA, or delete the branch if it was new |

Choosing Autonomous mode does **not** grant push. The first draft implied it did; it was corrected
because ADR-011 made push per-repository and off by default, and nothing about deciding alone changes
who should publish work to a remote. The wrapper is the only route once a repository has granted it.
A database *server* has no generic wrapper: dropping one is allowed only when `.harness/knowledge/`
records a dump command, which the engine runs into the trash first and records by hand.

Actions that no wrapper can make recoverable stay on the Deny List unconditionally, whatever the
mode: sending any message on anyone's behalf, deploying, publishing a package, calling a paid or
production API with side effects, touching the default branch, merging.

### New terminal status: `DONE_PARTIAL`

`DONE_PARTIAL` (exit 7) means the run exhausted its executable work with at least one of: an
abandoned task, an unsigned `human` criterion, or a Tier-3 assumption. It is a clean finish, not an
escalation: nothing is waiting for an answer before the engine can continue. It is reached the way
`DONE` is — the invocation that finds nothing left records a **PARTIAL-candidate** and reports
`CONTINUE`, and the next invocation, which wrote no code, re-proves the `machine` criteria and reports
`DONE_PARTIAL` without a Cleanup Commit. `ESCALATE` is never reported in Autonomous mode except for the
DoD approval. `FAILED` still is, for a broken environment no retry can repair. Budget exhaustion is
not `DONE_PARTIAL`: only the engine writes statuses, so a budget stop stays the Runtime's exit 5, with
the Run Report explaining it.

### The Runtime restarts instead of stopping

Past `MaxConsecutiveCrashes`, the Watchdog no longer stops an Autonomous run; it keeps re-invoking,
doubling the wait each time up to `-MaxCrashBackoffSeconds` (30 minutes by default). Collaborative
runs still stop at the limit. The human sets the budgets at launch — `/foreman --auto --hours 12
--iterations 300 …`, or `run.ps1 -MaxHours -MaxIterations` directly. The iteration budget is still
counted from commits (ADR-024), so a restart cannot reset it; the hour budget bounds one invocation of
`run.ps1`, which for an Autonomous run that never exits to ask is the whole run.

## The Run Report

Every Autonomous run ends with `RUN-REPORT.html` at the repository root, from
`templates/RUN-REPORT.template.html`. It is written after the engine's last checkpoint, so `run.ps1`
adds it to `.git/info/exclude`: never committed, and never a dirty tree the next run would mistake for
crash debris. It follows `.claude/field-reports.md` — a sticky topbar, a language `<select>`, English
at rest — and opens with the warning that the Deny List is not a security boundary. Its sections, in
reading order:

1. the outcome, its reason, the iterations and time spent, and the two ledger counts;
2. the Assumption Ledger, each entry with its revert command;
3. the Recovery Ledger — every destructive action taken, what was captured, how to restore it;
4. `.harness/ISSUES.md` — abandoned tasks, unfixed findings, and the `human` criteria "Awaiting a person";
5. the approved DoD;
6. `STATE.md`, collapsed.

After a `DONE`, the Cleanup Commit has already removed `.harness/run/`, so the Runtime reads each ledger
from the parent of the commit that deleted it.

**The Runtime renders it, not the engine.** The engine writes the two ledgers as structured Markdown
every Iteration, as part of its normal checkpoint. On any exit path — `DONE`, `DONE_PARTIAL`,
`FAILED`, budget, a crash it has given up backing off from — `run.ps1` fills an HTML template from
those files mechanically. Rendering is template substitution plus a line-by-line Markdown converter
that escapes everything it does not recognise — no judgment — so it belongs to the dumb Runtime of
ADR-002, and it is the only way the report exists after the exits the engine never sees coming.

## Found while building: `DECISIONS.md` was crash debris

Tracing where the mode file could live turned up a defect already present in Collaborative mode. The
Runtime provisions `DECISIONS.md` only once `.harness/run/` exists — that is, after the bootstrap
Iteration has already committed — so the Iteration after bootstrap always enters on a dirty tree, and
so does every Iteration after the human writes an answer. `ENGINE.md` §6.1 told the engine that any
dirty tree "means the previous invocation crashed" and to salvage or revert it. A `fake-claude` run that
checkpoints like the engine does shows the tree the second Iteration finds is exactly
`?? .harness/run/DECISIONS.md` and nothing else. §6.1 now names that file as never debris, to be
committed with the checkpoint; the Pester suite pins both the dirt and the exemption. It was not
observed in a field run — no engine is known to have reverted an answer — which is why it is recorded
here and not as a Ratchet lesson in its own right. §5 also claimed the Runtime provisions the file
"before your first invocation", which was false for the same reason, and now says when it actually does.

## Found in the first real run: a seven-day warning waited on the five-hour window

The first Autonomous run (Calendar-Note, `loop/music-player`, 2026-09-24) stopped after Phase 1 with
`Quota ceiling: five_hour at 45%` and a sleep until the five-hour reset, 2 h 31 min away. The raw
stream showed why: `status: allowed_warning, rateLimitType: seven_day, utilization: 0.88,
surpassedThreshold: 0.75`, with `five_hour` at 0.45. `Get-QuotaTrip` applied every CLI warning to the
five-hour window, a rule earned by a five-hour window going 40% → 100% inside one iteration (ADR-012).
A seven-day warning cannot be cleared by a five-hour reset, so the run would have woken, spent one
iteration, and slept again until its hour budget ran out. The same log line claimed `at/above 90%`,
which no window was.

The fix keeps the earned rule and narrows it to what earned it: only a warning whose `rateLimitType`
is `five_hour` (or which names no window) trips regardless of arithmetic. The seven-day window, which
moves slowly and is reported fresh in the same event, is judged against the ceiling like any other
reading. Two smaller changes came with it: the wait message names the rule that tripped instead of a
percentage, and a quota wait that would end after `-MaxHours` stops the run as `BUDGET` instead of
sleeping past the budget only to stop on waking. The run was stopped by hand, the fix pinned by three
Pester tests (`WARNED7` in the fixture is the field event), and the run relaunched from its Phase 1
checkpoint.

This matters more in Autonomous mode than it did before it, and is recorded here for that reason:
a Collaborative run that stalls on a wrong quota wait has a human nearby to notice; an Autonomous run
has nobody until the report.

## Considered Options

- **Autonomous mode as the only behaviour** — rejected by the human: supervised runs on a machine a
  person is sitting at remain better served by stops, for the same reason ADR-011 kept no-push as the
  default.
- **Let the engine pick the mode from the PRD's size or risk** — rejected: the choice of how much
  authority the engine holds is itself authority, and the engine never grants itself any (Invariant 3).
- **An autonomy charter listing which Tier-2 classes the engine may decide alone** — rejected by the
  human in favour of deciding every Tier-2 question and recording it. This was the closest call: a
  charter would bound the blast radius of a bad architectural guess, and it is the first thing to
  reach for if an Autonomous run's assumptions prove expensive to unwind.
- **A widened allow-list approved at launch instead of an inverted Deny List** — rejected by the
  human. It keeps ADR-004's model intact and is the safer design, but every command the list failed
  to anticipate becomes a dead end the engine has to route around with no one to ask.
- **Have the engine write the HTML report at the end** — rejected: a run that ends by budget, crash
  limit or `FAILED` never gets an Iteration in which to write it, which is exactly when the human
  most needs it.
- **Regenerate the HTML every Iteration, as `ISSUES.md` is** — rejected: it pays for a full HTML
  document in tokens on every Iteration to protect against a case that runtime rendering covers for
  free.

## Consequences

- The git directory gains `foreman-mode` (human-owned, engine-denied); `.harness/run/` gains
  `ASSUMPTIONS.md` and `RECOVERY.md` (engine-owned).
- The engine learns the mode from the last sentence of the iteration prompt (`Run Mode: …`), which
  sits outside the cached system prompt, so switching modes never breaks the spec's prompt cache.
  `CONTEXT.md` defines **Run Mode**, **Assumption**, **Recovery Wrapper**, **Deny List** and **Run Report**.
- **Not solved:** the deny rule names `.git/foreman-mode`, which is the git directory only in an
  ordinary clone. In a linked worktree the git directory is elsewhere and the rule does not cover it.
  It also denies only the `Edit` and `Write` tools; a shell command could still write the file — in
  Autonomous mode, where `Bash` is allowed wholesale, trivially. That is the same limit as the next
  item, not a separate one.
- The status contract grows from four words to five. `run.ps1`'s parser, the skill, and every
  document listing exit codes must learn `DONE_PARTIAL`.
- ADR-004's trust chain still holds in Autonomous mode, but the thing the human approves changes from
  a list of what is allowed to a list of what is not. The consumer guide's security posture section
  must say so as bluntly as ADR-011 said it about network access.
- ADR-007's non-blocking progress becomes total in Autonomous mode; ADR-015's `human` criteria stop
  blocking and start reporting.
- **Not solved: the Deny List is not a security boundary.** Claude Code's permission matcher is
  prefix matching over command strings. An engine with `allow: *` can write a script and run it, or
  reach a denied action through `bash -c`, a package script, or a tool that shells out. ADR-022
  already showed how much the matcher's behaviour can surprise a reasonable reading of it. The Deny
  List and the Recovery Wrappers protect against an engine that is *trying to follow the rules* and
  slips; they do not protect against one that routes around them. Autonomous mode is only as safe as
  the engine is well-behaved, and the report must say that at the top.
- **Not solved:** the database wrapper has to know the database. A dump command is stack-specific
  (`pg_dump`, `mysqldump`, copying a SQLite file, an Android Room database on a device), so it
  probably belongs in the stack packs under `skills/knowledge/`, and a stack with no dump recipe
  leaves database destruction on the Deny List.
- **Not solved:** `.harness/trash/` grows without bound over a long run and nothing cleans it up. The
  wrappers keep it out of every commit and out of `git status` through `.git/info/exclude`, so it is
  invisible — which also makes it easy to forget. The Recovery template tells the human to delete it.
- **Not solved:** the hour budget is per invocation of `run.ps1`. A human who relaunches an Autonomous
  run gets the hours again, as `MaxIterations` used to before ADR-024. It matters less here, because an
  Autonomous run only exits on a terminal status or a budget, but it is the same defect in a new place.
- **Open:** whether Collaborative mode should also get a Run Report. It costs nothing extra once the
  Runtime renders it, and the ledgers would simply be empty.
