# RESUME BLOCK

> Regenerated every iteration. The first thing a fresh iteration reads, and usually the only thing
> it needs before selecting work.
>
> **A derived cache, never a source of truth.** On any disagreement with the task files or with git,
> this file is the one that is wrong: correct it and trust the source. Recovery from a dirty tree
> always reads ground truth, never this.
>
> Keep it small. Every iteration pays to read it, and unlike ENGINE.md it is not served from a
> prompt cache. Never let history accumulate here.

- **Stage:** executing
- **Next Phase:** <!-- task ids, with each one's Declared File Scope -->
  - T-00x - scope: `src/...`
- **Queued decisions:** 0 <!-- and which tasks each blocks -->
- **Abandoned:** none <!-- task ids -->
- **Unreachable:** none <!-- task ids, and the abandonment blocking each -->
- **Verified commands:** build: `...` | test: `...` | lint: `...`
- **Model tiers (resolved from `.harness/loop/models.json`):** fast: `<identifier>` | capable: `<identifier>`
  <!-- Resolved here so a fresh Iteration can dispatch at a task's assigned tier without reading
       models.json itself. Without this the tier LABEL survives in the task file but nothing can
       resolve it, every dispatch silently inherits the Runtime's -Model, and the tier system is
       inert: Capable tasks run below Capable and the Reviewer is downgraded. Seen in the field. -->
