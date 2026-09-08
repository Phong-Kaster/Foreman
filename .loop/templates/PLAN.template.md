# PLAN

> Machine-owned execution strategy. The human never reviews this file - only the Definition of Done.
> Evolves through Tier-1 amendments (logged in AMENDMENTS.md) and Tier-2 queued decisions.

## Strategy

<!-- The intended shape of the work: order of attack, integration approach, verification approach. -->

## Task Graph

<!-- Task ids with dependencies and Declared File Scopes. Detail lives in TASKS/<id>.md. -->
- T-001 - ... (depends on: -) - scope: `src/...`
- T-002 - ... (depends on: T-001) - scope: `src/...`

## Phase Grouping

<!-- Produced by the conflict analysis at bootstrap and re-grouped freely as a Tier-1 amendment.
     A Phase needs: no unmet dependencies, pairwise DISJOINT file scopes, at most the cap in
     POLICIES.md. Shared/integration files belong to no task - the Iteration wires those itself. -->
| Phase | Tasks | Shared files the Iteration wires itself |
|---|---|---|
| 1 | T-001 | - |
| 2 | T-002, T-003 | `navigation/Routes.kt` |

## Known Risks

- ...
