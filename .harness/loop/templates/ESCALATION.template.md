# DECISION QUEUE

> Questions the engine could not answer within its authority. Queueing one does **not** stop the run:
> the engine marks the tasks that entry blocks and keeps working on everything else. The Runtime
> stops only when no executable task remains.
>
> Answer any number of entries - fill each `## Decision` section, then re-run. Unanswered entries
> stay queued and the tasks they name stay unselectable.

---

## D-001 - <short title>

- **Status:** pending | answered | archived
- **Type:** DoD approval | Tier 2 (plan/architecture) | Tier 3 (intent) | Capability grant | Missing information
- **Iteration:** N
- **Timestamp:** ...
- **Blocks tasks:** T-00x, T-00y
  <!-- LOAD-BEARING. A blocked task is unselectable, which is what makes it impossible for the
       engine to build on an unanswered question. An entry naming no tasks is a defect. -->

### Question

<!-- Exactly what the human is being asked to decide. -->

### Context

<!-- Why this arose; what was discovered. -->

### Options Considered

1. ... - consequences: ...
2. ... - consequences: ...

### Engine Recommendation

<!-- The engine's preferred option and why. -->

### Proposed Capabilities (if any)

<!-- Structured proposals. The human may narrow scope/lifetime, never the engine widening them.
     On approval: the approved entry is written into the named ledger file verbatim. -->
```json
{
  "intent": "...",
  "command": "...",
  "scope": "...",
  "lifetime": "goal",
  "allow": ["Bash(<exact rule>)"],
  "target_ledger": ".harness/run/capabilities.json"
}
```

### Decision

<!-- HUMAN WRITES HERE: the decision AND its rationale. The rationale becomes part of the audit trail. -->
