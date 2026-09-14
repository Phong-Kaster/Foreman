# A missing status is classified before it is retried; only a death mid-work is a Crash

The Runtime detected exactly one abnormal condition: `.ai/STATUS.md` absent after an invocation. That was defined as a **Crash**, and the Watchdog's reaction was to re-invoke up to `MaxConsecutiveCrashes` times and then stop with exit 2. `README.md` told the human exit 2 was "usually a transient CLI or network problem. Start it again."

A real run proved that one signal covers three different conditions, and that the reaction is correct for only one of them.

**The evidence** (Phong-Kaster/Calendar-Note, `loop/calendar-note-app`, 2026-09-11, twenty minutes into the calendar task):

```
[11:20:24] engine: You've hit your session limit · resets 2:30pm (Asia/Bangkok)
[11:20:24] engine invocation finished (success)
WARNING: Crash detected (no Execution Status). Consecutive crashes: 1 / 3
=== Iteration 2 === started 11:20:25
           ... same message ...              Consecutive crashes: 2 / 3
=== Iteration 3 === started 11:20:28
           ... same message ...              Consecutive crashes: 3 / 3
Watchdog limit reached. Stopping.                              exit 2
```

The CLI did not crash. It ran, declined on purpose, named both the condition and the reset time, and exited **0**. The entire Watchdog budget was spent in five seconds against a limit three hours from clearing, and the human was then advised to do the one thing guaranteed not to work.

The failure is not that the reaction was wrong. It is that **no classification happened before the reaction**. The three conditions behind an absent status are:

| Condition | Detectable by | Can a retry clear it? |
|---|---|---|
| **Never started** — CLI not on `PATH`, argument list too long, exec denied | an exception raised before the process ran | No. Permanent until the environment changes. |
| **Refused** — quota exhausted, not authenticated, no credit | the process exited having made no tool call, usually saying why | No. Permanent until a human acts. |
| **Died mid-work** — the genuine Crash | the process made tool calls, then ended without reporting | **Yes.** This is what the budget is for. |

Retrying the first two is not merely wasteful: it spends the budget that exists to absorb the third. A run that hits a quota limit and a transient network fault in the same hour now has no retries left for the fault that retrying would actually have fixed.

Three changes, all inside `run.ps1`:

1. **Classify, then react.** A launch exception and a refusal each stop immediately as `FAILED` (exit 4), relaying the launch error or the CLI's own refusal text verbatim — the CLI's wording usually names the remedy, and discarding it was the second half of the defect. Only "made tool calls, then died" increments the crash counter.
2. **Back off between crash retries** (`-CrashBackoffSeconds`, default 15, multiplied by the crash count). Three invocations inside five seconds was never a retry policy.
3. **Refusal patterns are narrow on purpose.** `session limit`, `usage limit`, `rate limit`, `quota`, `credit balance`, `insufficient credit`, and the authentication failures. `overloaded`, `529`, timeouts and connection resets are **deliberately absent**: those are transient by definition and must keep reaching the Watchdog. A test asserts this, so the list cannot be widened later without the widening being visible.

## The severity question, and the human's decision (2026-09-11)

The field report ranked the launch-failure half of this — *"the Watchdog cannot tell 'the engine died' from 'the engine never started'"* — as **high** severity, second only to the quota case. That rating was challenged and does not survive scrutiny:

- A launch failure destroys no work, spends **zero** tokens (the process never started), and produces no incorrect result. It stops the run, which is correct; it just stops it with the wrong label and misleading advice.
- Its true cost is a few minutes of operator confusion at setup time, plus three process spawns costing milliseconds.
- **Medium** is the honest rating. The report's "high" conflated *priority* with *severity*: the fix rides along with the quota fix for free, which is an argument about sequencing, not about damage.

**Decided by the human, 2026-09-11:** the fix ships as described; the report's severity label is left uncorrected, because the defect it described is already closed and re-labelling a finished finding buys nothing. This ADR is the durable record, and the report should be read with this correction alongside it.

**What would change this assessment.** The launch-failure path becomes genuinely high-severity the moment `ENGINE.md` outgrows the Windows command-line limit — roughly 32,000 bytes for the whole line, of which the spec was consuming 18,978 at the time of writing, and which grows every release because the ratchet writes to it. On that day every consumer repository fails simultaneously with `The filename or extension is too long`, and before this ADR they would all have been told it was probably transient. The severity then belongs to the ceiling, not to the misclassification — but the misclassification is what would have made it unreadable. Revisit this rating if that ceiling is approached.

## Considered Options

- **Leave the Watchdog as it was and fix the README's advice** — rejected: the advice was wrong because the classification was wrong. Correcting the words while leaving the runtime unable to tell the conditions apart moves the defect from the code into the documentation, where nothing can test it.
- **Treat every absent status as `FAILED` and drop the Watchdog** — rejected: an engine genuinely dying mid-work is a real and transient event, and ADR-002 is right that only the Runtime can detect it. Removing the retry would trade a rare wasted budget for a common lost run.
- **Detect a refusal from the process exit code instead of its output** — rejected: the CLI exits **0** on a quota refusal, which is arguably correct behaviour on its part (it ran, it reported, nothing crashed). The exit code carries no signal here; the text does.
- **Match refusals broadly (anything containing "limit", "error", "failed")** — rejected: it would swallow `overloaded_error` and the transient server-side faults the Watchdog exists for, converting a recoverable hiccup into a hard stop. Narrow patterns plus a test that pins the exclusion is the safer asymmetry — a missed refusal costs the old behaviour, a false refusal costs a run.
- **Have the engine write `FAILED` itself when it sees a quota message** — rejected: it cannot. The refusal comes from the CLI wrapper, before or instead of the engine getting a turn; there is no engine process to write a status file. This has to live in the Runtime, which is also where ADR-002 says mechanical fault handling belongs.

## Consequences

- The Runtime now reads engine output for a purpose other than display. This is a small widening of its remit and worth stating plainly: it still makes no engineering decision, but it is no longer purely a relay. The judgement it applies is a fixed literal-string list with no interpretation, which keeps it on the mechanical side of the line ADR-002 draws.
- `QuietEngine` mode cannot count tool calls, so the "ran but did no work" branch is skipped there and such an invocation still classifies as a Crash. Refusal detection still works, because the refusal text reaches stdout either way. Accepted: the quiet path is a debugging convenience, not the default.
- Exit 4 now means "broken **or** refused" rather than only "broken". The human-facing difference is carried by the message, not the code, so scripted consumers keying on exit codes are unaffected.
- `CONTEXT.md`'s definition of **Crash** narrows, and gains the two neighbouring conditions it is not. That vocabulary change is the point: "no status" is a symptom shared by three diagnoses, and naming them separately is what stops the next reader collapsing them again.
- **Not solved:** nothing bounds what a run may spend in wall-clock or money, and the iteration budget still resets on every process restart — so a run that escalates or crashes repeatedly has no effective ceiling. The backoff added here slows one path to runaway cost; it does not cap it. That belongs to a separate change.
