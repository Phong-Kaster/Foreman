# Every DoD criterion declares who can verify it, and human ones gate DONE

Completion in this architecture rests on evidence: a criterion is met when a command's output proves
it. That works exactly as far as the provable surface extends, and is blind beyond it — which is not
a gap in the evidence rule but its direct consequence.

Measured in the field. A run reached `DONE` with 31 criteria and 19 passing tests, and the delivered
screens had near-black text and a near-black delete icon on a black background. The delete button
existed, was correctly wired to the repository, and was invisible. The DoD had defined "delete works"
as "the fake repository removes the row", which was true. Nothing in the run could see a screen, so
nothing did.

Every DoD criterion therefore now declares a **Verification Class**:

- **`machine`** — provable by a command whose output can be read, or by a named file containing named
  content. The Verifier proves these itself, as before.
- **`human`** — requires a person to look at the running software. The Verifier cannot prove these
  and must not pretend to. Each carries an explicit instruction: what to open, what to do, what to
  expect.

The boundary is not a judgement call in most cases, and the default split is:

| Machine | Human |
|---|---|
| Business logic — CRUD correctness, date arithmetic, validation, scoping rules | Anything about appearance: colour, contrast, readability, spacing, alignment |
| Behaviour and flow — a navigation action reaches the intended screen, state transitions are correct, data survives a restart | Whether a control can actually be **seen and found** on screen |
| The app builds **and starts without crashing**, and each screen opens without throwing | Whether the result looks like the thing that was asked for |

**Building is not running.** The run that motivated this ADR required `assembleDebug` to succeed and
never required the app to launch. A compiled APK proves the code type-checks; it says nothing about
whether a screen renders. Where a device or emulator is available, launch-and-open-each-screen is a
`machine` criterion and should be written as one.

**A user-facing capability usually needs one criterion of each class, and this is the rule that would
have caught the failure above.** "The user can delete a note" is two separate claims: the deletion
logic removes the record (`machine`, provable against a repository), and the delete control is
visible and reachable on the screen (`human`). The run asserted only the first, proved it correctly,
and shipped a button rendered near-black on black. Splitting the capability makes the second claim
impossible to omit silently.

**A `human` criterion that is not signed off blocks `DONE`.** At Verification the engine proves every
`machine` criterion, then queues a Human Verification Request — a numbered checklist — and reports
`ESCALATE`. Only once every item is signed may a later iteration report `DONE`.

**A DoD covering user-facing behaviour with zero `human` criteria is itself a defect**, and the
critique role must reject it. Zero is not a sign of a well-specified requirement; it is a sign the
DoD is measuring a layer beneath the one the user experiences.

## Considered Options

- **Leave it as is and rely on the human reviewing the branch** — rejected, because that is what
  already happened. The run reported `DONE`, which is a claim of verified completion, and the human
  reasonably read it as one. A status word that overstates what was checked is worse than no status.
- **Require instrumented or screenshot tests so everything stays `machine`** — rejected as the general
  answer. It needs an emulator or device in the loop, which many consumers will not have; it makes
  the DoD gate depend on infrastructure rather than intent; and screenshot tests answer "did this
  change" rather than "is this right", so the first baseline still needs a human. Worth adopting per
  repository where the infrastructure exists — it moves criteria from `human` to `machine`, which is
  a strict improvement — but it cannot be the mechanism the architecture depends on.
- **Let the engine judge visual correctness itself** — rejected. It cannot see the running app, and
  the run that motivated this ADR demonstrates the failure precisely: the engine had every file in
  front of it, correctly wired the delete button, and had no way to notice the result was invisible.
- **Block mid-run on each human criterion as it becomes checkable** — rejected: it destroys ADR-007's
  non-blocking progress for no gain. The checklist is cheaper for the human as one batch at the end,
  and nothing downstream depends on the answer until `DONE` is at stake.
- **Warn rather than block** — rejected. An advisory that `DONE` might be wrong is exactly the
  situation this ADR exists to end.

## Consequences

- `DONE` now means: every `machine` criterion re-proved by a fresh Verifier, **and** every `human`
  criterion signed off by a person. It is a stronger claim than before, and an honest one.
- An unattended run with unsigned `human` criteria ends at `ESCALATE` holding a checklist, not at
  `DONE`. That is the intended trade: a truthful stop beats a false completion. ADR-007 is unaffected
  — the loop still runs to exhaustion without stopping for questions; this gate sits at the very end.
- The Human Verification Request must be **specific enough to act on without reading the code**: open
  this screen, do this, expect this. "Check the UI looks right" is not a criterion, it is an apology
  for not having written one.
- ADR-005 narrows accordingly: the Verifier certifies the `machine` half. It never had the standing to
  certify the other half, and previously did so implicitly by reporting `DONE`.
- ADR-001's DoD gate now approves the classification as well as the criteria. A criterion silently
  classed `machine` when only a person can judge it reproduces the original defect exactly, so the
  critique role checks classes, not just wording.
- The Issues Report lists unsigned `human` criteria, so a human returning to a stopped run sees what
  is waiting for them without opening the Decision Queue.
- Cost of being wrong is asymmetric and the classification should lean accordingly: over-classifying
  as `human` costs one look; under-classifying ships something like a delete button nobody can see.
