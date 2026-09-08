# The Runtime owns four mechanical bounds, including quota

A loop that runs with minimal supervision needs bounds that do not depend on the engine's judgment or its obedience. The Runtime owns exactly four, all mechanical, all judgment-free:

| Bound | Default | Detects |
|---|---|---|
| **Idle timeout** | 20 min with no stream event | A hung invocation — a working engine emits `tool_use` events continuously |
| **Hard timeout** | 90 min per Iteration | An invocation that emits events forever without converging |
| **Quota ceiling** | 90% utilization, **whichever window trips first** | Approaching the account's usage limit |
| **Iteration budget** | 50 per run | An engine reporting `CONTINUE` forever on an impossible goal |

The quota bound is possible because `claude -p --output-format stream-json` emits a `rate_limit_event` carrying structured utilization — verified against the CLI, not inferred:

```json
{"type":"rate_limit_event","rate_limit_info":{
  "status":"allowed","rateLimitType":"five_hour","resetsAt":1788868200,
  "unifiedWindows":{"five_hour":{"utilization":0.37,"resetsAt":1788868200},
                    "seven_day":{"utilization":0.18,"resetsAt":1789308000}}}}
```

The Runtime tracks the **peak** utilization seen (not the latest — a later event can report lower), checks **between** Iterations, and reacts: below the ceiling, invoke again; at or above it, either stop or sleep until `resetsAt` and resume. An explicitly `rejected` status is a **quota wait, never a Crash** — it does not increment the Watchdog counter.

Two things a real run taught, both of which changed this design:

**`status` has three values, not two:** `allowed`, `allowed_warning`, `rejected`. Code that asks "is the status not `allowed`?" classifies a merely-warned invocation as a rejection — so an invocation that crashed for an unrelated reason while the account was near its limit would put the Runtime to sleep for hours instead of letting the Watchdog retry. That is precisely the silent-hang failure this design exists to avoid. **Only an explicit `rejected` is a rejection.**

**The ceiling cannot preempt a single expensive Iteration, and no threshold can.** The utilization reading available between Iterations was measured when the *previous* Iteration began making calls. One observed Iteration cost $0.84 and consumed the window from roughly 40% to 100%, passing `allowed_warning` at 96%, 97%, and 99% mid-stream before being `rejected` — so a 90% ceiling evaluated on between-Iteration data never fired, and the loop reached 100% anyway. Two mitigations, both now in place: track the peak seen mid-stream rather than the last value, and **treat the CLI's own `allowed_warning` as a trip regardless of the arithmetic**, since the CLI knows the true remaining headroom and the Runtime's figure may be stale. What remains true is structural: the ceiling is a guard on *starting another* Iteration, not on finishing the current one. Where Iterations are costly relative to the window, the ceiling must be set lower.

Timeouts kill the process and count as a Crash, so existing recovery applies unchanged: the next invocation finds a dirty tree and recovers per `ENGINE.md` §6.1. Quota waits are excluded from both timeouts.

## Considered Options

- **A wall-clock deadline ("stop at 07:00")** — rejected. It was the wrong shape: the goal is a proactive loop needing minimal supervision, not a fixed nightly window. The correct progress bound is already ADR-007's *no executable task remains*; what the Runtime additionally needs is a **resource** bound, not a time-of-day bound.
- **A human-declared token budget (`-QuotaTokens`) as the quota denominator** — rejected once `rate_limit_event` was verified to carry `utilization` directly. Asking the human for a denominator the client already knows is worse in every respect.
- **A dollar ceiling from `total_cost_usd`** — rejected as the primary bound: it measures absolute spend, not headroom remaining, so it cannot express "leave me 10%". Retained as an optional secondary bound, with one trap that must be documented for whoever implements it: **the stream emits a `result` event on every subagent completion as well as the main one, and `total_cost_usd` on each is the session-cumulative figure, not that subagent's own.** Summing `result` events therefore multiplies the bill by the number of subagents. Measured in the field: naive summation gave $79.64 where the true spend was $16.95, a 4.7x overstatement — a cost bound built that way would trip at roughly a fifth of the real figure. Group by `session_id` and take the maximum per session.
- **Watching only the five-hour window** — rejected: `seven_day` utilization exists and a long run can exhaust it, locking the human out for days rather than hours. Both windows must be checked.
- **The engine checks its own quota (`/usage`)** — rejected on plane grounds. A mechanical safety bound belongs to the Runtime (ADR-002); an engine deciding when to stop for cost reasons is exercising judgment it does not own. The Runtime's signal is also more precise than the human-facing warning.
- **A single aggressive timeout of 15–20 minutes total** — rejected: an Iteration running three Workers plus a build, tests, and review legitimately exceeds it, and a killed legitimate Iteration counts as a Crash, so three of them end the run. The two failure modes are not symmetric, so the bound must err generous. The idle timeout is what actually detects a hang.

## Consequences

- Detecting a quota wait removes a concrete defect: before this ADR, exhausting the quota produced no `STATUS.md`, so the Watchdog read it as three Crashes and ended the run. Verified end to end in a real run: the Runtime saw `rejected`, did not count a Crash, and slept until the reported reset.
- After a wait completes, the recorded peak and warning flag must be **cleared**. Carrying them across a reset would trip the ceiling instantly on the next check and the loop would never resume.
- The Runtime must log a heartbeat while waiting ("waiting for quota reset, resumes HH:MM"). A silent stream reads as a hang to a human watching the feed, and to the Skill's Monitor.
- The idle threshold must exceed the longest legitimate single tool call, because one `Bash` call emits no events while it runs. A clean Android build can exceed ten minutes; 20 min is chosen against that, and is the first number to revisit per project.
- `result` events carry `subagent_stats`, including `refused.concurrency_limit` — so the ceiling on concurrent Workers is **observable and must be discovered**, never assumed (see ADR-008).
- `rate_limit_event` is Claude-Code-specific in name and shape, so it joins the adapter leak list in ADR-006.
- All four bounds remain policy-free: exhausting one produces a deterministic report, never an interpretation of whether the work was going well.
