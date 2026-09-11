# Architecture Decision Record Convention

## Objective

`docs/adr/` holds the reasoning behind each hard-to-undo choice. These are not summaries of what was
built — they are the record of *why the alternative was rejected*, written so that a reader in a year
can tell whether the reasoning still holds.

An ADR is earned the same way a `POLICIES.md` line is (the Ratchet): a real failure, a real
measurement, or a decision with a real trade-off. A change with one obvious correct answer does not
need one.

---

# Filename

```text
docs/adr/ADR-<NNN>-<kebab-case-title>.md
```

Zero-padded to three digits, sequential, never reused. Existing: `ADR-001` … `ADR-023`, with 007-016 belonging to the `.harness` lineage and 017+ to the line that merged into it.

---

# Title

The `# H1` is a **sentence stating the decision**, not a topic label. A reader should be able to
learn what was decided without opening the file.

Good — real titles from this repository:

```text
# Stateless iterations driven by an intentionally dumb runtime

# Knowledge is stratified by whose failure history earned it; domain truth outranks the codebase

# Known defects live in knowledge/ISSUES.md, addressed by commit SHA, and the engine may read history

# A piped exit code is not evidence; `set -o pipefail` is a baseline capability
```

Avoid:

```text
# Knowledge management

# Decisions about the watchdog

# ADR-009
```

---

# Structure

There is no rigid template. Every ADR here has these three movements, in this order:

## 1. The problem, opened with evidence (no heading)

Start with what was true before and what broke. Quote the real log line, the real measurement, the
real commit. The reader should meet the failure before meeting the solution.

```text
A run reported a verified `DONE` while leaving a defect its own reviewer had found.
Tracing why produced three separate faults, none of which was a reasoning failure.
```

Then state the decision and its mechanism. Sub-headings (`##`) are fine here when the ADR carries
more than one change.

## 2. `## Considered Options`

Every serious alternative, each with **why it was rejected**. This is the most valuable section and
the one most often written too thin.

```text
- **One `knowledge/` file for everything, as before** — rejected: it forces one conflict rule onto
  two kinds of truth, and the rule is backwards for domain truth in a way that silently converts a
  coding bug into the project's specification.
```

Mark the option that was nearly chosen. "This was the closest call" tells a future reader where the
decision is most likely to need revisiting.

## 3. `## Consequences`

What follows mechanically from the decision — including the costs.

**End with what is still open.** Every ADR here does. Use bold `**Not solved:**` or `**Open:**`.

```text
- **Not solved:** nothing verifies that an `ISSUES.md` entry is still true. A defect fixed by a
  human between runs leaves a stale entry until an iteration happens to notice.
```

An ADR with no open consequence is usually an ADR that has not been examined hard enough.

---

# Recording a human decision

When the human rules on something — a severity rating, a scope call, an approval — record it in the
ADR with **the date and what would overturn it**:

```text
**Decided by the human, 2026-09-11:** the fix ships as described; the report's severity label is
left uncorrected, because the defect it described is already closed.

**What would change this assessment.** The launch-failure path becomes genuinely high-severity the
moment `ENGINE.md` outgrows the Windows command-line limit...
```

A decision without a revisit condition is a decision nobody can safely re-open.

---

# Linking

An ADR that nothing references will not be found. When adding one, link it from wherever the
behaviour it governs is described:

- `docs/architecture.md` — at the section the decision changes
- `CONTEXT.md` — if it narrows or redefines a term
- `README.md` — only if it changes something a user of the product would notice

Inline, in prose, as `([ADR-00N](./adr/ADR-00N-….md))`. There is no index file to update.

---

# Writing style

Match the existing ADRs:

- Prose, not bullet-point fragments. These are arguments, and arguments need sentences.
- Present tense for what the system does, past tense for what happened.
- Real identifiers: repository names, branch names, commit SHAs, file paths, measured numbers.
- Name the principle being applied when one applies — "a rule enforced by a script is a rule, a rule
  living only in a prompt is a wish (ADR-002)".
- Never write "it was decided that". Say what was decided, and by what reasoning.
