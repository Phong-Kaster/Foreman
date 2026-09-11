# PROJECT KNOWLEDGE

> Engine-maintained cache of **verified** operational truth about this repository. Survives every feature run.
> Human-editable without approval. It is a cache, never the source of truth: on conflict, the codebase wins and the engine corrects this file.
>
> This file is the only mechanism by which run *n+1* starts smarter than run *n*. Everything in it is
> split by one question: **if a Worker ignored this, would the result be wrong?**

## Constraints

<!-- TRAPS. "Never X here, because Y." Violating one produces a defect, not untidiness.
     These are carried VERBATIM into every Worker Brief (ADR-016) - never filtered, never
     summarised, never judged relevant or irrelevant by the dispatching Iteration. The Fresh-Context
     Review checks the diff against this list and a violation is a BLOCKING finding.

     Keep them few and terse. If everything is a Constraint the Brief becomes a wall of text with
     the important line buried, which is the failure this section exists to prevent. A Constraint
     earns its place by having cost something: a defect, a failed attempt, a review finding.

     Cite evidence (file:line) so each one can be checked, and DELETE it when the code changes and
     it stops being true - a stale Constraint misleads worse than a missing one.

     Prefer a lint rule or a test wherever the trap can be mechanised. Constraints are for the ones
     that resist mechanisation. -->

- **Never** … because … — evidence: `path/to/File.kt:NN`

## Toolchain (verified commands)

<!-- Only commands that have actually been run successfully. Record the command and what "success" looks like. -->
| Purpose | Command | Verified |
|---|---|---|
| Build | … | yes/no |
| Unit tests | … | yes/no |
| Lint | … | yes/no |

## Architecture Conventions

<!-- Reference, not Constraints: where code goes and what shape it takes. Filtered into a Worker
     Brief as needed. Violating one is untidy; violating a Constraint is wrong. -->
- …

## Environmental Facts

<!-- Hard-won lessons that are not traps: JDK/SDK versions, emulator requirements, flaky suites,
     slow modules, proxy quirks. If one of these means a Worker would produce a WRONG result rather
     than a slow one, it belongs in Constraints instead. -->
- …

## Sources Consulted

<!-- Human docs read at bootstrap (never edited by the engine): CLAUDE.md, README, CI config… -->
- …
