# The Decision Queue splits into an engine-owned file and a human-owned file the engine cannot write

`.harness/run/ESCALATION.md` held both halves of a decision: the engine appended the question, and
the human filled in the same file's `## Decision` section with the answer. The field report found
this caught mid-write:

> Waiting for `.ai/ESCALATION.md` to appear and then writing a decision into it caught the engine
> mid-write: it logged "recording the partial decision", consumed a half-written answer, and
> recovered on its own.

The design had two independent defects, not one:

**Two writers, one file, no atomicity.** `ENGINE.md` §7 appends the question and then explicitly
keeps working — "mark those tasks deferred and keep working on something else. Do not stop." — so
the file existing is not the same as the engine being done with it. Nothing stopped the engine from
appending a second, unrelated entry later in the same Iteration while a human's freshly-written
answer sat in the same file, and a read-modify-write append racing a human's editor save is exactly
how a half-written decision gets read as real.

**No completion signal.** The correct signal that it is safe to answer is the process actually
exiting (`Status: ESCALATE`, `run.ps1` exit 3) — `ADR-002`'s whole claim that a Tier-2 stop is
"enforced mechanically... rather than by model obedience" depends on that exit having happened. A
file's mere existence on disk is not that signal, and the consumer guide's manual path pointed
readers at the file, not the exit.

## The decision

Two files, one writer each:

- **`.harness/run/ESCALATION.md`** — unchanged in shape, minus the `## Decision` section. The
  engine's own log: questions, context, options, recommendation, capability proposals, blocked
  tasks. The engine may append to it at any time.
- **`.harness/run/DECISIONS.md`** — new. The human writes here, under a heading naming the entry's
  id (`## D-001`). The engine is denied `Edit` and `Write` on this path in `run.ps1`'s permission
  compiler, the same mechanism that already protects `.harness/knowledge/DOMAIN.md` and the
  Capability Ledgers. This is what makes "the engine never writes it" a property enforced by the
  Runtime rather than a line in a spec the engine could reason around — the same principle ADR-002
  already applies to the ledgers themselves.

`ENGINE.md` §6.2 now reads `DECISIONS.md`, once, at the start of the Iteration, and never re-opens
it before the next one begins — so a decision written while the current Iteration is still running
cannot be consumed early and cannot collide with anything, because the engine has no path left that
writes that file at all. An id with no matching queued entry, or a body that is empty or plainly cut
off, is treated as not yet answered rather than guessed at.

The engine cannot write `DECISIONS.md`, so it also cannot create it. `run.ps1` provisions it
mechanically — `Ensure-DecisionsFile`, copying `.harness/loop/templates/DECISIONS.template.md` —
the same pattern already used for `Publish-AgentDefinitions` and the compiled permission settings:
a build artifact the Runtime is responsible for because the party who needs it is the party denied
the ability to make it.

## Considered Options

- **Keep one file; have the engine treat the whole file as immutable once written, checking a hash
  before any append** — rejected: this still requires the engine to *read* the file to compute the
  comparison, which is exactly the operation that raced a human's in-progress write in the field
  incident. The defect is a shared file, not a missing check on it.
- **Have the engine stop immediately after queuing a decision, rather than continuing to work** —
  rejected: this is the design ADR-007 deliberately moved away from (non-blocking progress). Making
  the file's lifetime short would narrow the race window but not close it, and it reintroduces the
  exact idleness ADR-007 was written to remove.
- **A lock file (`.harness/run/ESCALATION.lock`) held during any write** — rejected: a lock only
  helps two cooperating writers, and `run.ps1` already refuses concurrent engine invocations (the
  run lock). The actual second writer is a human with a text editor, who will not check a lock file
  before saving. Denying the engine write access removes the second writer entirely instead of
  asking both parties to cooperate around one.
- **Name the human's answer file `ESCALATION.md.answer` or similar, sitting next to the original** —
  rejected as a naming-only variant of the same idea; `DECISIONS.md` was chosen to read naturally
  next to `ESCALATION.md` and to generalize past Escalation Requests to any future artifact needing
  a human-only answer channel.

## Consequences

- This is the same mechanism ADR-004 already uses for the Capability Ledgers and `DOMAIN.md`:
  human-owned truth is protected by a deny rule, not a request. `DECISIONS.md` is the third artifact
  in that family, and the pattern (`Ensure-*File` mechanical provisioning, paired with a deny rule)
  is now established enough to reuse directly for a fourth.
- `CONTEXT.md`'s **Escalation Request** definition narrows to the question half only; a new
  **Decision** term names the answer half and where it lives.
- Every doc describing the manual path (`docs/consumer-guide.md`, `docs/architecture.md`) now says
  explicitly to wait for `Status: ESCALATE`, not for `ESCALATION.md` to appear — the completion-signal
  half of the original defect, which the file split alone does not fix for a reader who still writes
  too early into the *right* file relative to when they think the engine is done. Writing early into
  `DECISIONS.md` is harmless (nothing else writes it, so there is nothing to corrupt); it is only
  ever consumed a shade later than the writer expected, at the start of whichever Iteration follows.
- **Not solved:** nothing validates a `DECISIONS.md` entry's shape beyond "not empty, not obviously
  truncated." A well-formed but nonsensical answer (approving a different id than the one intended,
  say) is still consumed as written — that class of mistake was never in scope here and belongs to
  whatever eventually reviews `AMENDMENTS.md` for coherence.
- **Not solved:** `docs/architecture.md` §6 still claims "at most one pending escalation at a time,"
  which `ENGINE.md` §7's "keep working on something else" appears to contradict — multiple entries
  can plausibly queue in one run for different blocked tasks. That drift predates this change and is
  independent of the file-split defect; it is noted here only because it sits in the same paragraph
  this ADR rewrote.
