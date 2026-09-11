# Fresh-context review per task; DONE requires a verifier that wrote nothing

The dominant failure mode of self-review is shared misunderstanding: the context that introduced a wrong assumption is the least likely context to detect it. Two rules engineer the bias out:

1. **Fresh-Context Review (per task):** a clean-context subagent reviews each implementation, receiving only the diff, the task description, the Definition of Done, project standards, and evidence — never the implementation reasoning, because that reasoning may contain the original mistake. Findings flow into Reconcile.
2. **DONE-Candidate rule (per goal):** the iteration that completes the last task may never emit DONE. It checkpoints with CONTINUE and records DONE-candidate in STATE. The next, fresh iteration — which produced none of the code — re-verifies every DoD criterion against evidence, and alone may emit DONE (or files gap tasks and the loop continues).

The builder creates. The reviewer challenges. The verifier confirms.

## Considered Options

- **Self-review in the authoring context** — rejected: catches typos, structurally blind to its own wrong assumptions.
- **Review as a separate iteration for every task** — rejected for V1: doubles iteration count; the subagent gives fresh eyes at far lower cost. Kept only where independence matters most — the completion claim.

## Consequences

- Completion is declared by a context that never wrote the implementation, which is the property §Verification demands but cannot otherwise enforce.
- **Narrowed by [ADR-015](./ADR-015-human-verifiable-criteria.md):** the Verifier certifies the `machine` half of the DoD. It cannot see the running software, so it never had standing over the rest — and by reporting `DONE` it was implicitly claiming that standing anyway. A run whose `human` criteria are unsigned now stops at `ESCALATE` with a checklist instead.
- Cost: one subagent call per task, plus exactly one extra iteration per run.
