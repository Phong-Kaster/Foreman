# Stable Checkpoint is a loop concept; git is one persistence backend

A **Stable Checkpoint** is defined as a verified execution state that is safe to resume from — not as "a git commit". For git repositories (all V1 consumers), the engine persists each checkpoint as **one atomic commit containing both code changes and `.ai/` state**, on a dedicated local Loop Branch. One Iteration produces exactly one Stable Checkpoint produces (at most) one commit.

## Considered Options

- **Checkpoint = git commit, by definition** — rejected: the architecture should own its concepts rather than inherit them from a tool; a future non-git backend must not require redefining the loop.
- **Git-free state files only** — rejected: nothing would enforce that STATE.md matches the code around it.
- **Runtime-driven commits** — rejected: deciding what is commit-worthy is judgment, and judgment never lives in the Runtime.

## Consequences

- Code + state committed atomically means STATE.md at HEAD always describes HEAD — they can never desync.
- Crash recovery is mechanical: a dirty working tree at iteration start means the previous iteration died mid-flight; the engine salvages or reverts to the last checkpoint.
- `git log` on the Loop Branch is the execution history; the audit trail is free.
- At verified completion, a **Cleanup Commit** removes `.ai/` from the branch tip: `.ai/` is the loop's memory while it works, not the product the human merges. Its history remains in the branch's commits. The completion summary travels in the Cleanup Commit's message.
- The engine never touches the default branch and never merges. Merging is a human act, always. (Pushing the Loop Branch was later permitted under an explicit capability grant -- see [ADR-011](./ADR-011-loop-branch-push.md) -- which does not change the branch's append-only character or who may merge.)
