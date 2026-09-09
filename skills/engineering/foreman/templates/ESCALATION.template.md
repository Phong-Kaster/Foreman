# ESCALATION REQUEST

> The engine persists this before stopping whenever a decision exceeds its authority.
> Fill the **Decision** section (decision + rationale), then re-run the Runtime. At most one pending request at a time.

- **Type:** DoD approval | Tier 2 (plan/architecture) | Tier 3 (intent) | Capability grant | Missing information
- **Iteration:** N
- **Timestamp:** …

## Question

<!-- Exactly what the human is being asked to decide. -->

## Context

<!-- Why this arose; what was discovered. -->

## Options Considered

1. … — consequences: …
2. … — consequences: …

## Engine Recommendation

<!-- The engine's preferred option and why. -->

## Proposed Capabilities (if any)

<!-- Structured proposals. The human may narrow scope/lifetime, never the engine widening them.
     On approval (V1): the human pastes the approved entry into the named ledger file. -->
```json
{
  "intent": "…",
  "command": "…",
  "scope": "…",
  "lifetime": "goal",
  "allow": ["Bash(<exact rule>)"],
  "target_ledger": ".ai/capabilities.json"
}
```

## Decision

<!-- HUMAN WRITES HERE: the decision AND its rationale. The rationale becomes part of the audit trail. -->
