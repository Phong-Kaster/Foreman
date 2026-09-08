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

The Runtime tracks the latest event seen, checks **between** Iterations, and reacts: below the ceiling, invoke again; at or above it, either stop or sleep until `resetsAt` and resume. A `status` indicating rejection is a **quota wait, never a Crash** — it does not increment the Watchdog counter.

Timeouts kill the process and count as a Crash, so existing recovery applies unchanged: the next invocation finds a dirty tree and recovers per `ENGINE.md` §6.1. Quota waits are excluded from both timeouts.

## Considered Options

- **A wall-clock deadline ("stop at 07:00")** — rejected. It was the wrong shape: the goal is a proactive loop needing minimal supervision, not a fixed nightly window. The correct progress bound is already ADR-007's *no executable task remains*; what the Runtime additionally needs is a **resource** bound, not a time-of-day bound.
- **A human-declared token budget (`-QuotaTokens`) as the quota denominator** — rejected once `rate_limit_event` was verified to carry `utilization` directly. Asking the human for a denominator the client already knows is worse in every respect.
- **A dollar ceiling from `total_cost_usd`** — rejected as the primary bound: it measures absolute spend, not headroom remaining, so it cannot express "leave me 10%". Retained as an optional secondary bound.
- **Watching only the five-hour window** — rejected: `seven_day` utilization exists and a long run can exhaust it, locking the human out for days rather than hours. Both windows must be checked.
- **The engine checks its own quota (`/usage`)** — rejected on plane grounds. A mechanical safety bound belongs to the Runtime (ADR-002); an engine deciding when to stop for cost reasons is exercising judgment it does not own. The Runtime's signal is also more precise than the human-facing warning.
- **A single aggressive timeout of 15–20 minutes total** — rejected: an Iteration running three Workers plus a build, tests, and review legitimately exceeds it, and a killed legitimate Iteration counts as a Crash, so three of them end the run. The two failure modes are not symmetric, so the bound must err generous. The idle timeout is what actually detects a hang.

## Consequences

- Detecting a quota wait removes a concrete defect: before this ADR, exhausting the quota produced no `STATUS.md`, so the Watchdog read it as three Crashes and ended the run.
- The Runtime must log a heartbeat while waiting ("waiting for quota reset, resumes HH:MM"). A silent stream reads as a hang to a human watching the feed, and to the Skill's Monitor.
- The idle threshold must exceed the longest legitimate single tool call, because one `Bash` call emits no events while it runs. A clean Android build can exceed ten minutes; 20 min is chosen against that, and is the first number to revisit per project.
- `result` events carry `subagent_stats`, including `refused.concurrency_limit` — so the ceiling on concurrent Workers is **observable and must be discovered**, never assumed (see ADR-008).
- `rate_limit_event` is Claude-Code-specific in name and shape, so it joins the adapter leak list in ADR-006.
- All four bounds remain policy-free: exhausting one produces a deterministic report, never an interpretation of whether the work was going well.
