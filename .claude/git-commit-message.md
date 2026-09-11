# Commit Message Convention

## Objective

Every commit in every repository touched by this project uses one shape:

```text
loop(<scope>): <summary>
```

The **prefix is always `loop`**. Only the scope vocabulary differs by repository, because the two
have different things to name:

| Where | Scope is | Written by |
|---|---|---|
| **This repository** | an area of the product — `engine`, `runtime`, `policies`, … (below) | you |
| **A consumer repository** | a task id (`T-007`) or `bootstrap` / `decision` / `knowledge` / `infra` / `complete` | the engine, per `.loop/POLICIES.md` |

> **History note.** Commits before 2026-09-11 use a sentence style with no prefix
> (`stratify knowledge by owner; domain truth outranks the codebase`). They are legible and are not
> being rewritten — the branch is an audit trail. Everything from here conforms.

---

# Scope vocabulary for this repository

Pick the scope that names **what the change is about**, not every file it touched. Changes here
routinely span `ENGINE.md`, `POLICIES.md` and `templates/` at once; that is one decision, not three
scopes.

| Scope | Covers |
|---|---|
| `engine` | The engine's operating contract — `ENGINE.md`, the iteration algorithm, the status contract |
| `policies` | Engineering policy — `POLICIES.md`, retries, review standards, evidence rules |
| `runtime` | `run.ps1` — the enforcement plane, the Watchdog, the capability compiler |
| `capabilities` | The permission model — baseline ledger, risk classes, the trust chain |
| `knowledge` | The knowledge model — `PROJECT`/`ISSUES`/`DOMAIN`, stack packs under `skills/knowledge/` |
| `skill` | The `/foreman` skill — `SKILL.md`, packaging, installation |
| `templates` | `.loop/templates/` — the blueprints for `.ai/` and `knowledge/` |
| `docs` | `README.md`, `docs/architecture.md`, `docs/consumer-guide.md`, `CONTEXT.md` |
| `adr` | An ADR added or revised |
| `tests` | `tests/` — the Pester suite and the `fake-claude` fixture |
| `repo` | Repository plumbing — `.claude/`, `.gitignore`, tooling, CI |

If a change genuinely has no single centre, use the scope of the decision that motivated it. If two
unrelated things are being committed, they are two commits.

## The scope is a functional area, never an implementation detail

Name the part of the product a reader would go looking in, not the file that happened to change.

Good: `engine`, `runtime`, `capabilities`, `knowledge`, `policies`

Avoid: `markdown`, `json`, `powershell`, `regex`, `function`, `variable`

---

# The kind of change lives in the verb

There is no type prefix here — `loop` is fixed. The distinction Conventional Commits carries in its
*type* is carried in this repository by **the verb the summary opens with**. Pick the most specific
one that is true.

| Kind of change | Open with | Example |
|---|---|---|
| New capability or behaviour | `add`, `grant`, `introduce`, `ship` | `loop(capabilities): grant pipefail so a piped exit code can be trusted` |
| Bug fix | `fix`, `correct`, `close` | `loop(runtime): fix the crash counter resetting on every restart` |
| Internal restructure, **no** behaviour change | `refactor`, `extract`, `split`, `merge`, `move`, `rename` | `loop(runtime): extract the capability compiler from the loop body` |
| Documentation only | `document`, `clarify`, `correct` | `loop(docs): document the two-copy parity rule` |
| Build, dependencies, project config | `upgrade`, `pin`, `bump` | `loop(repo): pin Pester to 5.x for the runtime suite` |
| Tests only | `test`, `cover`, `pin` | `loop(tests): cover both capability-ledger typo modes` |
| Performance or resource bounds | `bound`, `reduce`, `speed up` | `loop(engine): bound STATE.md against run length` |
| Formatting or style only | `format`, `reorder` | `loop(repo): reorder the baseline ledger by risk class` |
| Maintenance, cleanup | `remove`, `delete`, `drop` | `loop(repo): remove the unrelated third-party skill collection` |
| CI / release workflow | `add`, `update` (scope `repo`) | `loop(repo): add the parity check to pull-request validation` |
| Revert | `revert` | `loop(runtime): revert the pipefail grant` |

## Restructuring verbs require unchanged behaviour

`refactor`, `extract`, `split`, `move`, `merge` and `rename` may be used **only when observable
behaviour is identical before and after** — for the engine, the runtime, and any consumer
repository. If anything would behave differently in any case, it is not a restructure: say what
changed instead.

A commit that reads as a tidy-up while quietly changing behaviour is the hardest kind to find
later, precisely because nobody re-reads it.

## Choose the most specific verb that is true

When two fit, take the narrower one. `fix` beats `add` when the behaviour was meant to work already;
`bound` beats `fix` when the change is about a limit. Reach for `remove` or `document` before falling
back to anything vague — this repository has no equivalent of a `chore`, and a change that resists
every verb above is usually two changes.

---

# Summary

The summary must:

- open with an imperative verb from the table above — `add`, not `added` or `adding`;
- say what changed, specifically enough to be searched for;
- stay on one line, comfortably inside ~72 characters where it can;
- be lowercase, and **not** end with a period.

It describes **the shift in what the system does or believes**, not the diff.

Good:

```text
loop(knowledge): stratify by owner so domain truth outranks the codebase

loop(runtime): classify a missing status before retrying it

loop(capabilities): grant pipefail so a piped exit code can be trusted as evidence

loop(engine): read the commit log at bootstrap before declaring anything missing

loop(policies): ratchet the first batch of UI lessons into review standards
```

Avoid:

```text
loop(engine): update ENGINE.md

loop(runtime): fix bug

loop(docs): various improvements

loop(policies): changes requested
```

## Name the artefact, not the activity

The log is read later by someone — or something — searching it. `loop(knowledge): add host-side
Compose screenshot testing (no emulator)` is findable. `loop(knowledge): wire up testing` is not.
This is the same rule ADR-011 imposes on engine-written commits, for the same reason.

---

# Body

This is where the convention carries most of its weight. The body is usually **several paragraphs**,
and is expected to be substantial when the change is.

## Lead with the evidence that forced the change

Foreman changes because something failed. Open with the measurement, the failing run, or the
incident — not with what you did.

```text
Measured on the Calendar-Note run: 16-27 lines per iteration entry, 209 lines of
history after only four iterations — roughly 20 lines per iteration. Extrapolated
to the 18-50 iterations a 53-criterion PRD implies, that is 470-1100 lines, read
in full at Orient every single iteration...
```

Real numbers, real repository names, real branch names, real SHAs. A change justified by reasoning
alone has not been earned — see the Ratchet, below.

## Use underlined section headings for multi-part commits

```text
STATE.md no longer grows with the run
-------------------------------------
```

Plain text with a dashed underline, not Markdown `##`, so the message reads correctly in `git log`
on a terminal.

## Name what you found while looking

Discoveries that were not the point of the commit still belong in it:

```text
Found while looking: the current design is worse than its predecessor here. The
older .harness runtime kept STATE.md (95 lines) separate from HISTORY.md...
```

## Cite the ADR, and say when a change depends on an earlier one

```text
This is only safe because of yesterday's work. Before Bash(git show*) entered the
baseline ledger, trimming history would have destroyed it instead of relocating it.
```

## State what the change does *not* fix

Consistent with how every ADR here ends. A commit that closes one gap and leaves a neighbouring one
open should say so, rather than letting a reader assume the area is finished.

---

# What earns a commit at all

This repository is governed by the **Ratchet** (`.loop/POLICIES.md`, ADR-007): a line is earned by a
real failure — a broken build, a failing test, a review finding, a denied command — and removed once
the model no longer needs it.

A commit adding doctrine to `ENGINE.md` or `POLICIES.md` must name the failure that earned it, in
the body. Anticipated problems are not failures; "this could be a problem later" is not a commit
message. `ENGINE.md` is injected as system prompt on every invocation, so an unearned line does not
merely cost tokens — it makes the earned lines matter less.

---

# The two copies must move together

`.loop/` and `skills/engineering/foreman/` are byte-identical copies of the same distributable. A
commit changing one and not the other is broken even though it builds and every test passes — see
`.claude/distributable-parity.md`, and run `.claude/skills/verify-distributable` before committing.
Never split the two across separate commits.

---

# Attribution

End the message with the attribution line the session specifies, when one is given. Do not invent
co-authors.
