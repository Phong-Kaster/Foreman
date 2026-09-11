# Definition of Done

> Derived from `PRD.md` at bootstrap. Human-owned after approval: the engine may propose changes (Tier 3) but never apply them.
> Every criterion must be verifiable by evidence, and must declare WHO can verify it (ADR-015).

## Status

- [ ] APPROVED — approve via the pending `.harness/run/ESCALATION.md`; edit criteria freely before approving.
      Approval covers the Verification Class of each criterion, not only its wording.

## Acceptance Criteria

<!-- One criterion per line, each tagged with its Verification Class.
     [machine] a command's output or a named file proves it; the Verifier proves it itself.
     [human]   a person must look at the running software; blocks DONE until signed off.

     Business logic, behaviour/flow, and "builds AND starts without crashing" are [machine].
     Appearance, contrast, and whether a control can be SEEN and FOUND are [human].

     A user-facing capability usually needs one of each. "The user can delete a note" is both
     "the record is removed" [machine] and "the delete control is visible and reachable" [human].
     A DoD with user-facing behaviour and NO [human] criteria is a defect: it is measuring a layer
     beneath the one the user experiences. When uncertain, choose [human]. -->
1. [machine] …
2. [human] … — open …, do …, expect …

## Constraints

<!-- Non-negotiable boundaries from the PRD: architecture rules, compatibility, performance floors. -->
- …

## Verification Evidence Required

<!-- [machine]: the exact command and the output that proves it.
     [human]:   what to open, what to do, what to expect — written so a person can act on it without
                reading any code. "Check the UI looks right" is not evidence, it is an apology for
                not having written a criterion. -->
| Criterion | Class | Evidence / what to look at | Signed off |
|---|---|---|---|
| 1 | machine | `gradlew test` … | n/a |
| 2 | human | open …, do …, expect … | ☐ |
