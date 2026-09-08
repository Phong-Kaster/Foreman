# The engine may push the Loop Branch, never the default branch

`ENGINE.md` Invariant 7 forbade pushing outright. For unattended overnight execution that is too strict: a machine failure at 3am loses the entire night's verified work, and the human cannot review progress from another device in the morning.

Amended: the engine may push **the Loop Branch only**, under an explicit Capability grant. Never the default branch, never `--force`, never a rebase, never a merge, never a pull request opened on the engine's own authority. Merging remains a human act, permanently.

## Considered Options

- **No push at all (V1)** — rejected for unattended runs, for the two losses above. It remains correct for a supervised run on a machine the human is sitting at.
- **Push the default branch, or open a PR automatically** — rejected: merging is a human act (ADR-003), and CI firing on every unverified intermediate checkpoint is noise that trains the human to ignore it.
- **Push as a baseline capability shipped with the runtime** — rejected: network access is High-risk under `POLICIES.md` § Capability Risk Classes and must cross the same explicit approval boundary as any other high-risk grant. A repository with no remote, or a human who does not want their intermediate work published, must get the old behavior by default.
- **Push only at DONE** — rejected: it protects nothing that matters and loses exactly the property the change is for, since a 3am crash happens before DONE.

## Consequences

- Network access enters the engine's capability surface. The honest security posture note in the consumer guide must say so explicitly, alongside the existing High-risk scanner disclosure.
- Because the Loop Branch is append-only and never rewritten, the remote copy is a faithful audit trail rather than a moving target.
- The Issues Report and the Phase-level commit messages become remotely readable, which is what makes a morning review from another device possible — the practical point of the change.
- The capability is per-repository standing (approved at the DoD gate) rather than goal-scoped, since it applies to every checkpoint of the run. That makes it a deliberate, visible grant, not an incidental one.
