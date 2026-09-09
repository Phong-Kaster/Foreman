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
- **Type:** DoD approval | Tier 2 (plan/architecture) | Tier 3 (intent) | Capability grant | Missing information | **Human verification** (ADR-015)
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
  // target_ledger is DERIVED from lifetime, never chosen separately:
  //   "goal"      -> ".harness/run/capabilities.json"       (expires with run/)
  //   "permanent" -> ".harness/knowledge/capabilities.json" (survives future runs)
  // Proposing "goal" against the knowledge ledger makes the grant permanent in
  // fact while calling itself temporary. Nothing downstream cross-checks it.
}
```

### Decision

<!-- HUMAN WRITES HERE: the decision AND its rationale. The rationale becomes part of the audit trail. -->

---

## Human Verification Request — template

<!-- Queued by the Verifier when every `machine` criterion holds but `human` criteria are unsigned.
     The run stops here: no Cleanup Commit, no DONE, until every item below is marked.
     Each item must be actionable WITHOUT reading code. Written badly ("check the UI looks right")
     this gate is worthless; written well it is the only thing standing between a green test suite
     and a delete button rendered invisible against its own background. -->

- **Status:** pending
- **Type:** Human verification
- **Blocks:** `DONE` only — every task is complete and every `machine` criterion has been re-proved.

### How to run this check

Build and install: `<exact command>`. Then work through the list. Mark each item `PASS` or
`FAIL: <what you saw>`. A FAIL is a normal discovery, not a rejection of the run.

| # | DoD criterion | Open | Do | Expect | Result |
|---|---|---|---|---|---|
| 1 | 30 | Calendar screen | tap a day with a note | the note's text and its delete icon are both clearly legible against the background | |
| 2 | 24 | Calendar screen | tap the delete icon on a note | the note disappears from the list | |

### Decision

<!-- HUMAN WRITES HERE: PASS/FAIL per row above, plus anything you noticed that is not on the list.
     Anything you report here that no row asked about is itself a finding: it means the DoD had a
     gap, and the gap should be recorded, not just fixed. -->
