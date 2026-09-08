# Progress never blocks on a single question or a single failed task

Unattended overnight execution requires that neither a question nor a failure can idle the run. Two rules replace the V1 hard stops:

1. **Decisions are queued, not awaited.** A decision exceeding the engine's authority is persisted to the **Decision Queue**, and the entry names every task it blocks. Those tasks are marked deferred; the engine selects the next task with no unmet dependency and continues.
2. **The third failure abandons the task.** A task failing its third attempt is marked abandoned, and every task transitively depending on it is marked unreachable rather than attempted.

The engine reports `ESCALATE` only when **no executable task remains** and the queue is non-empty or tasks were abandoned — a batch at the end of the night, not an interruption at 00:15. The four status words, their meanings, the exit codes, and the Runtime's reaction table are all unchanged; only the trigger for `ESCALATE` moved. `DONE` keeps its strict meaning: every DoD criterion verified by a fresh Verifier, nothing abandoned, nothing deferred.

## Considered Options

- **Keep the V1 hard stop on the first escalation** — rejected: a single question at 00:15 idles the remaining eight hours. This is the one defect that prevented unattended running.
- **A fifth status word for partial completion** — rejected: `ESCALATE` already means *human decision required*, which is exactly what a batch of queued questions is. A fifth word would change the Runtime's reaction table and erode ADR-002's intentionally dumb runtime for no gain.
- **Let the engine answer its own intent questions and record an assumption** — rejected: violates Invariant 3 and Tier 3. It is the mechanism by which a loop spends eight hours confidently building the wrong feature.
- **Abandon a failed task without cascading to its dependents** — rejected: the loop would spend the night failing at work whose foundation is missing, and would exhaust the iteration budget on unreachable tasks.

## Consequences

- The V1 invariant "at most one pending Escalation Request" is retired, replaced by the Decision Queue. `.ai/ESCALATION.md` becomes a queue of entries rather than a single pending request.
- **Parking is safe only because tasks declare dependencies.** A queue entry that fails to name the tasks it blocks is a defect: it would allow the engine to build on an unanswered question. This is the load-bearing rule of the whole design.
- `ENGINE.md` §6.2 narrows from "never proceed past an unanswered escalation" to "never proceed past an unanswered escalation *on the tasks that escalation blocks*".
- `POLICIES.md`'s retry policy changes its terminal branch: the third failure reconciles to **abandonment**, not escalation.
- A global question (a technology choice, a contradiction in intent) blocks nearly every task through the dependency graph, so the loop runs out of executable work and reports quickly. The graph makes global and local questions behave correctly without a special case.
- DoD approval remains the **single blocking gate**: approved before the run starts, after which nothing stops the loop for a question until it runs out of work.
- A run can now end with unmet DoD criteria. That outcome is `ESCALATE`, never `DONE` — so ADR-005's completion guarantee is untouched.
- Because a run can end incomplete, the **Issues Report** becomes necessary rather than optional: abandoned tasks with their three failure reasons, queued questions, unfixed review findings, and recorded assumptions must survive the Cleanup Commit that removes `.ai/`.
- The iteration budget stops being the primary safety bound for a long run. The bound that replaces it is a **resource** bound, not a time-of-day one — see ADR-012, which also establishes that exhausting the account quota is a wait, never a Crash. "No executable task remains" is the progress bound; the quota ceiling is the resource bound; neither is a clock.
