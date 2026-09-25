# RECOVERY

> Autonomous mode only (ENGINE.md §14.3, ADR-027). Every action this run took that `git revert` alone
> cannot undo, with what was captured first and the exact command that restores it. Entries are
> appended by the Recovery Wrappers in `.harness/loop/bin/`; the engine appends one by hand only for a
> database dump taken from a recipe in `.harness/knowledge/`. Nobody edits an entry after it is written.
>
> Captured copies live in `.harness/trash/`, which is excluded from git and never cleaned up
> automatically. Delete it yourself once you are satisfied nothing needs restoring.

---
