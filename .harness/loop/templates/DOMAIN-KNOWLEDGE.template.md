# DOMAIN KNOWLEDGE

> **Human-owned.** Durable truth about this project's problem domain — rules, formulas, algorithms,
> regulatory constraints, business invariants. Survives every feature run.
>
> The engine may **read** this file and may **propose** entries through an Escalation Request. It can
> never write here: runtime deny rules protect this path, the same way they protect the Capability
> Ledgers. Only you (or the Skill transcribing a decision you approved, verbatim) add or change entries.
>
> **This file beats the codebase.** That inverts the rule for `PROJECT.md`, and the inversion is the
> whole point: `PROJECT.md` caches facts *about* the code, so the code corrects it. A domain rule is
> not a fact about the code — the code is an *attempt* at it. When they disagree, the code is wrong.
> The engine must treat the difference as a defect to report, never as a reason to edit this file.
>
> Create this file only if the project actually has durable domain rules. An empty one is clutter;
> delete it rather than leaving a stub.

## Rules and Invariants

<!-- One entry per rule. State it precisely enough to be implemented and tested from this text alone.
     Cite the authority (standard, paper, spec, regulation, internal decision) so it can be re-checked.
     Note the source's own version/date where the rule can change over time. -->

### <rule name>

- **Rule:** …
- **Authority:** …
- **Applies to:** …
- **Do not confuse with:** …

## Formulas and Algorithms

<!-- Exact expressions, units, valid input ranges, rounding, and the behaviour at boundaries.
     Units and boundary behaviour are where implementations silently diverge — be explicit. -->

| Name | Expression | Units | Valid range | Boundary / rounding | Authority |
|---|---|---|---|---|---|
| … | … | … | … | … | … |

## Terminology

<!-- Domain words whose everyday meaning differs from their meaning here. -->

| Term | In this project it means | Not to be read as |
|---|---|---|
| … | … | … |

## Known Divergences

<!-- Where the codebase currently disagrees with a rule above, and why it has not been fixed yet.
     Recording it here keeps a known defect from being mistaken for the rule. -->

- …
