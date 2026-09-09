# OPEN ISSUES

> Engine-maintained list of **known-wrong things that are still wrong**. Survives every feature run
> because it lives in `knowledge/`, alongside `PROJECT.md`, and is read at Orient every iteration.
>
> **Its semantics are the opposite of `PROJECT.md`'s, and the distinction is the entire point.**
> `PROJECT.md` records how this repository *is* — conventions to conform to. This file records what
> is *wrong* with it — things to **not** copy. Recording a defect in `PROJECT.md` does not merely
> fail to help: a later iteration reads it as the local convention and reproduces the defect on
> purpose. That has already happened once (see ADR-008).
>
> Human-editable without approval, like `PROJECT.md`.

## How an entry earns its place, and how it leaves

- **Add** an entry when something is known to be wrong and is **not being fixed in this iteration**:
  a review finding filed rather than fixed, a defect outside the current run's scope, a decision the
  human deferred, an assumption that will bite later.
- **Do not add** what you just fixed. A fixed defect belongs in the commit, not here.
- **Delete** the entry the moment it is resolved. This file is worth reading only while everything
  in it is still true; a resolved entry left behind teaches the next reader to distrust the rest.
- Keep each entry to what a reader needs in order to decide whether it blocks them.

## Pointing at the full record

Every entry must be **self-contained enough to act on**, then point at the detail by **commit SHA** —
never by a path alone. `.ai/` is removed from the branch tip at completion, so a reference like
"see the escalation in `.ai/ESCALATION.md`" resolves to nothing the moment the run finishes. The
commit that held it is permanent; the path inside it is not.

Read a prior run's state back with:

```
git show <sha>:<path>
```

## Entries

<!-- Newest first. Delete resolved entries outright rather than marking them done. -->

### <short title>

- **What is wrong:** …
- **Where:** `path/to/file.kt:LINE`
- **Why it is still open:** … (out of scope / human deferred it / blocked by … )
- **What would resolve it:** …
- **Full record:** `git show <sha>:<path>` — <what lives there>
- **Do not:** … (the mistake a later iteration would make by treating this as the convention)
