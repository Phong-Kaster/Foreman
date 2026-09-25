# The Runtime pins the Iteration's Model Tier, and records what every iteration cost

> **Renumbered from ADR-024 on 2026-09-25**, because `main` already had [ADR-024](./ADR-024-the-iteration-budget-is-counted-from-commits-not-a-process-variable.md). Commits on `loop/fix-guide-language-toggle` made before that date still cite it as ADR-024.

A run that produced good work — 251 tests, 0 lint errors, no abandoned task, 36 DoD criteria — was
reported by the human as taking far too long for what it built. Answering "why" turned out to be
impossible from anything the product writes down, which is the first finding. `run.ps1` measured
every iteration's duration and passed it to `Write-Host`; nothing on disk held a number afterwards.
The answer had to be reconstructed from `%TEMP%\loop-run-Calendar-Note.raw.jsonl`, a debug artifact
that survived by luck and covered only the run's second day.

What it showed, for that day alone:

| | |
|---|---|
| Wall clock | 6.49 h |
| Engine actually running | **3.08 h (47%)** |
| One quota block | **2 h 38 m** |
| Waiting for a human | ~46 m |
| Cost | $78.42 |
| Context re-read | 143 M tokens across 645 turns |

Three separate faults sat underneath those numbers.

## The tier system was inverted, not merely unenforced

`run.ps1` passed `--model` only when a human supplied `-Model`. Nobody did, so the top-level session
inherited whatever the CLI defaults to, for the whole run. Attributing every assistant message in the
event stream to its role:

| Role | Model it actually ran on | What `POLICIES.md` required |
|---|---|---|
| Orchestrator (top-level session) | Sonnet — 979 of 1,215 messages | "Always Capable, no exception" |
| `loop-worker` (subagent) | Opus — 378 messages | eligible for Fast |
| `loop-reviewer` (subagent) | Opus — 221 messages | Capable ✓ |

The role the specification forbids downgrading ran cheap; the only role tiering was ever meant to
touch ran expensive. Iteration 9 — the Verifier, which re-proves every `machine` criterion precisely
because the builder cannot be trusted to grade itself — ran without a single Capable-tier message.

**Decision: the Runtime resolves the tier and passes `--model` itself.** One model is fixed for an
entire invocation, so this is the last moment a choice exists; the engine cannot switch its own model
at §11. `STATE.md`'s DONE-candidate is the signal, the same flag `ENGINE.md` §6.3 already branches
on, so the two cannot drift apart. Ordinary iterations run Fast; the Verifier iteration runs Capable.

**Decided by the human, 2026-09-15:** the Orchestrator stays at Fast rather than being raised to
Capable as the old wording demanded. The measured run *is* the evidence for it — that configuration
built the feature the human accepted — and raising it would move 184 M cache-read tokens onto Capable
pricing, roughly doubling the bill to fix something no observed failure is attributable to. **What
would change this assessment:** an Orchestrator-authored merge, shared-file wiring, or reconciliation
error that a Capable-tier session would plausibly have caught. The Verifier is not part of this
trade — it is pinned to Capable unconditionally.

## A tier nothing ever selects is a comment

Fast mapped to the cheapest available model. Across the whole run it was chosen **zero** times: 7 of
7 tasks were classified Capable, and the Fast model consumed 6,363 input tokens and one cent.

The three criteria in `POLICIES.md` are not at fault. A planning role that will not stake a
Kotlin/Compose task on the cheapest model is behaving exactly as intended, and loosening the criteria
to force the tier into use would trade correctness for a number. **Decision: raise what Fast maps
to**, in `models.json`, which exists to be the one place a vendor model name appears. The Workers
that ran at Capable can now be dispatched at a tier a cautious planner is willing to pick.

## The same grant was requested four times

Eight decisions were queued. Four of them — D-003, D-004, D-006, D-007 — were one screenshot-reference
grant, asked once per case, each one stopping the loop until a person came back. The reason a human
sat there is recorded honestly in the commit that withdrew the standing grant:

> Recording a new reference for a state that never had one is the safe half; overwriting a
> currently-failing one is not, and the permission matcher cannot tell them apart.

The matcher cannot. A script can. `record-new-references.ps1` hashes every existing reference before
invoking Gradle and restores any that changed, so only new files survive; an attempted overwrite
exits 2 with the originals intact. That is granted once, goal-scoped, and covers the rest of the run.

**Decision: a run-scoped grant covers a kind of action, not one literal command line**, and the
engine must read `capabilities.json` before queueing a capability decision. Asking again is correct
only when the new action falls outside what was granted — a wider blast radius, a different tool, or
the inverse of the granted act. Widening is a new decision; repeating is not.

## Considered options

- **Persist timing only, and tune later** — rejected as insufficient on its own, though it is the
  prerequisite for everything else and shipped first. Without the token and cost columns the row
  cannot distinguish a slow Gradle from an expensive model, which is the actual question.
- **Raise the Orchestrator to Capable to satisfy the existing wording** — rejected above; this was
  the closest call in this ADR, and the one most likely to need revisiting.
- **Delete the Fast tier outright** — genuinely on the table, since a tier used zero times costs more
  in specification weight than it saves. Rejected because the measurement showed the mapping was
  wrong, not the concept; a tier that nothing selects at one mapping may be selected often at
  another, and deleting it would also delete the escalation path a failed Fast attempt uses.
- **Grant the raw `updateDebugScreenshotTest` for the whole run** — rejected: it hands the engine a
  one-command route to making a failing visual test pass by rewriting the expectation, which is the
  exact act the withdrawal commit existed to prevent. The wrapper buys the same silence without it.
- **Have the Runtime generate `SUGGESTIONS.html`'s Escalate tab itself** — rejected: it is a
  markdown-to-HTML transformation of arbitrary human prose, far past what an intentionally dumb
  runtime should contain (ADR-002). The Runtime *verifies* instead, and opens the raw
  `ESCALATION.md` when the page is missing a pending id.

## Consequences

- `.harness/TELEMETRY.tsv` accumulates one row per iteration, deliberately outside `.harness/run/`,
  which the Cleanup Commit deletes. Nine rows answer in a glance what took a day of forensics here.
- `ESCALATE` opens the decision queue in the browser. A page missing any pending `D-0NN` is treated
  as stale and skipped in favour of the raw file — showing yesterday's questions is worse than
  showing none, because it reads as answered. `-NoOpenEscalation` suppresses the browser, never the
  check.
- Two display bugs fixed in passing, both the `[int]` rounding trap this repository already
  documents: `[int]3.95` is 4, so the quota heartbeat counted *up* — `04:02 remaining` followed five
  minutes later by `04:57 remaining` — and elapsed time was wrong by up to an hour in both
  directions.
- `ENGINE.md` grew 2,071 bytes and `POLICIES.md` 2,971. Nothing was retired to pay for it. Under the
  Ratchet that is a debt, not a neutral fact: every line is injected on every invocation of every run
  in every consumer repository.

- **Not solved: the context growth itself, which is the largest number here.** 222 K tokens carried
  per turn on average and 767 K at the worst session; 55% of the bill was re-reading cached context.
  `POLICIES.md` now requires evidence to be written to a file and read back in summary, but that is a
  rule addressed to a model, and nothing measures compliance. The telemetry's `cache_read_tokens`
  column is where the evidence for or against it will appear.
- **Not solved: quota exhaustion, the single biggest time sink.** One 33-minute iteration took the
  five-hour window to 97% and the loop then idled 2 h 38 m. `run.ps1` says plainly that no
  between-iteration ceiling can preempt a single expensive iteration. Lowering per-iteration
  consumption is the only real remedy, which makes it the same open problem as the line above.
- **Not solved: nothing verifies that the Fast tier is now actually selected.** The mapping changed;
  whether planning roles choose it is a behaviour, observable only in the next run's task files. If
  the count is still 0 of N, the conclusion is that the criteria are the binding constraint after
  all, and this ADR's second decision was wrong.
