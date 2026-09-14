# A perceptual criterion may be `machine` only if it cites the reference image behind it

`POLICIES.md` § Evidence Requirements offers exactly two routes when the Definition of Done carries a
requirement no command can observe — appearance, contrast, layout, anything about what a user can
perceive:

> - propose the capability that would make it provable …; or
> - escalate that the criterion needs human inspection, and record it as such.

`ENGINE.md` §5 step 6 binds DoD generation to that same pair. The vocabulary is binary: **(M)** a
command's output, or **(I)** a human looking at a screen. The Calendar-Note run inherited the binary
and declared four DoD criteria to contain clauses no command could ever prove.

That was false when it was written. Having imported the screenshot harness, the engine recorded
references, **opened the generated PNGs and read them**, and then said:

```
"Validation passes — but a green validate against a just-recorded reference
 proves nothing. Checking the harness can actually fail:"
   → perturbed Color.kt, re-ran validate to confirm it goes red
```

The negative control is the eye-catching part. The consequential part is the step before it: a
multimodal engine reading a rendered image is a real act of perception, performed by the machine, and
the doctrine has no name for it. By the end of the run it had produced 20 reference images on
`loop/calendar-note-app`, 692 KB under `app/src/screenshotTestDebug/reference/`, including combined
states such as *"Day cell — today, picked, with notes"* — precisely the overlap where the previous run
shipped a `primary` dot on a `primary`-filled circle, invisible to the one user who looked.

**The decision: name (V) engine-inspected render as a third evidence class — but only after the
permission layer, not the prose, has put the reference baseline out of the engine's reach.**

## The composition, not the perception, is what makes it evidence

(V) alone is worthless and must never be admissible alone. It is a judgement, not a measurement: two
invocations may read the same image differently, and nothing reproduces it from the checkpoint, which
is what § Evidence Requirements demands of evidence. What makes it admissible is that it composes
with (M) and then gets out of the way:

```
(V)  engine opens the render, judges "the notes dot is legible on the picked fill"   ← happens ONCE
      ↓
     that render is pinned as a reference PNG and committed
      ↓
(M)  validateDebugScreenshotTest                                      ← runs forever, red on drift
```

The weak, unreproducible step is confined to a single moment and then locked behind a reproducible
one. The perceptual judgement is made once; the machine defends it thereafter. This is why (V) is
strictly stronger than declaring a criterion unprovable, and strictly weaker than (I).

## The ordering constraint, which is the whole of this ADR

Every limit that makes (V) safe is prose, and prose is a wish (ADR-002). "Never the sole proof."
"Only against a pinned reference." Nothing enforces either. **Exactly one** part of the (V) contract
is mechanically enforceable, and it is the capability asymmetry the stack pack already names as *"the
most important line in this pack"*:

```
Bash(*validateDebugScreenshotTest*)     ← grant
Bash(*updateDebugScreenshotTest*)       ← do NOT grant
```

`update` overwrites the reference images. An engine holding it, facing a red screenshot test, has a
one-command route to making the failure disappear by re-recording wrong output as correct — the same
class of act as editing the approved DoD.

That asymmetry is **not in force in the field today**, and the chronology is the finding:

| Date | Event |
|---|---|
| 2026-09-09 | `78e7fd6` ships the stack pack to this repository, withholding `update` |
| 2026-09-10 | `4c55bb0` in Calendar-Note consumes escalation D-001 and grants `update` **standing** |

`D:/Valve/Calendar-Note/knowledge/capabilities.json` carries both tasks in one entry with
`"lifetime": "standing (per repository, survives this goal)"`. The pack's own
`capabilities.snippet.json` — written first — exists to prevent that entry. So at the moment the
engine was performing (V) unprompted, it also held, permanently, the command that launders its
result.

This is why the ordering is not a matter of taste. Naming (V) as a blessed evidence class while the
laundering route is open does not merely fail to help; it certifies the one configuration in which
(V) is dangerous. The mechanical change comes first, and the doctrine follows it.

## What changes

**Step 1 — capability, before any doctrine (`knowledge/capabilities.json`, per consumer repo).**
Split the screenshot entry in two. `validate` stays standing. `update` leaves the standing ledger and
becomes goal-scoped, granted at an escalation once a human has agreed a baseline change is
intentional — the pattern the Cleanup Commit already uses. Enforced by the permission matcher, which
does not depend on the model's cooperation.

**Step 2 — `POLICIES.md` § Evidence Requirements.** Name the third class where the two routes are
listed, with its limits stated in the same breath:

- **(V) engine-inspected render** — the engine opens a rendered image and judges it. Admissible
  **only** when the render is pinned by a committed reference image, so that (M) can defend the
  judgement afterwards. Never the sole evidence for a criterion. Never evidence for anything
  safety-critical. An engine that cannot point at the reference file has not produced (V); it has
  produced an opinion.

**Step 3 — `ENGINE.md` §5 step 6.** Where DoD generation currently offers "propose the capability or
escalate", insert (V)+(M) ahead of escalation: a perceptual criterion is escalated to (I) only when
no pinned render can stand behind it. The rule to write is a preference order, not a new permission —
the engine already has the ability.

**Step 4 — `skills/knowledge/android/compose-visual-testing/SKILL.md`.** The pack presents the
harness as a pure (M) mechanism and never says the engine can read the image, which is the capability
that makes the harness worth installing. Say it, and say what it does not license.

## Considered Options

- **Leave the binary as it is** — rejected, and this is the option most easily mistaken for the safe
  one. Silence did not prevent (V); the engine performed it unprompted in a run where doctrine had no
  name for it. The choice is not between having (V) and not having it, but between a governed (V) and
  an ungoverned one — and under the ungoverned version a reviewer has no line to cite when the engine
  over-claims, because no line exists.

- **Name (V) in `POLICIES.md` and leave capabilities untouched** — rejected. This was the closest
  call, because it is what the field report's own Fix section proposes: three doctrine edits and no
  capability edit. It blesses a perceptual evidence class in a repository where the engine can
  re-record the baseline in one command. Certifying a mechanism while its only mechanical guard is
  absent is worse than certifying nothing.

- **Keep escalating every perceptual criterion to (I)** — rejected. Each `ESCALATE` is a
  stop-and-restart by design, so a UI-shaped PRD becomes a sequence of human interrupts, and the
  autonomous loop stops being autonomous for the entire class of work Foreman is most often pointed
  at. Worse, it raises the pressure toward the route `POLICIES.md` already forbids: quietly narrowing
  the criterion to its machine-checkable subset. That pressure has already won once — the invisible
  dot passed a green unit test asserting the note existed in the model.

- **Withhold `updateDebugScreenshotTest` outright, with no goal-scoped path back** — rejected: it
  also forbids *creating* a reference for a state that never had one, so every new screen becomes an
  escalation and the coverage stops growing. The dangerous act is not recording a new baseline; it is
  overwriting one that is currently failing.

- **Distinguish the two acts mechanically** — adopted in principle, deferred in practice. In git the
  two are already distinct: an additive pin appears as a **new** file, a laundering pin as a
  **modified** one. A commit-time check could refuse the latter without a human grant. It is not
  built, and `updateDebugScreenshotTest` re-records everything in one invocation, so the permission
  matcher alone cannot express the distinction — only a check over the diff can.

## Consequences

- Perceptual criteria stop being escalation triggers. A criterion that can fail replaces a criterion
  that was declared unprovable, which is the only thing that fixes silent narrowing — more review
  passes do not, because a reviewer cannot find what the DoD never defined.

- Combined states become coverable, and they are where the defects live. The individual states of the
  day cell were all correct; the overlap was not.

- The first pin becomes the load-bearing moment of the whole chain, and the capability split puts a
  human at it for any *change* to an existing baseline while leaving new coverage to the engine.

- `ENGINE.md` and `POLICIES.md` are injected as system prompt on every invocation, so the limits
  prose has a per-iteration cost. It is earned under the Ratchet — an observed live behaviour, four
  criteria falsely declared unprovable, and a shipped defect — but it should be written tight.

- Reference images are tracked binaries. Growing coverage grows the repository, and an intentional UI
  change now requires a human grant before the baseline can move.

- **Not solved:** nothing verifies that the engine actually opened the image. "(V) requires a pinned
  reference" is checkable in principle; "the engine looked, and judged soundly" is not checkable at
  all. (V) can be bounded, never audited.

- **Not solved:** the additive-versus-mutating check is described here and not built. Until it is,
  Step 1 is enforced at grant time only, and a human who grants `update` goal-scoped for a legitimate
  baseline change hands over both acts for the duration.

- **Open:** the 20 reference images now on `loop/calendar-note-app` and `main` were all pinned while
  the engine held `update` standing. One has been inspected by hand since (the combined day-cell case,
  correct). The remaining nineteen have not. Nothing in this decision re-validates a baseline recorded
  under the configuration it exists to prevent.

- **Open:** `loop/todo-calendar-screens` carries 34 reference images against the field report's
  recorded 15. The branch moved after the report was written; no one has checked what the difference
  contains.

**Decided by the human, 2026-09-11.** Adopted, with one change to the shape: **not** a third
verification class. `ADR-015`'s axis is *who verifies*, and after the first pin the verifier really is
the machine, forever — so a perceptual criterion stays `machine` and must **name the reference file**
standing behind it. Without one it remains `human`. This keeps the taxonomy on one axis and leaves
every branch on Verification Class with two arms instead of three.

Step 1 landed first, as this ADR requires: `Calendar-Note@a48229b` withdrew the standing
`updateDebugScreenshotTest` grant that `D-001` had wrongly given, verified by
`validateDebugScreenshotTest` still passing under the narrowed ledger. The engine is deny-listed from
that file by design; it was edited on the human's explicit one-time authorisation, to correct an entry
the engine itself had written.

_What would overturn it: What would overturn it:
evidence that a model reading its own rendered output is unreliable enough that (V)+(M) admits defects
(I) would have caught, or a commit-time check that makes the goal-scoped `update` grant unnecessary._

---

# REBASE ANCHORS - spent 2026-09-11 at HEAD 6048811

All four were re-checked before promotion. What had moved:

| Anchor | Recorded | At promotion |
|---|---|---|
| Next free ADR number | 017 | 017, unchanged - 007-012 still carry merge-duplicated pairs |
| Taxonomy to extend | `machine` / `human` (ADR-015) | unchanged, and **kept at two** per the decision above |
| Step 1 target | `Calendar-Note/knowledge/capabilities.json` | done, `a48229b` |
| ADR-022 `pipefail` question | 0 occurrences - dropped or orphaned? | **orphaned by the merge.** The `.loop` ledger carrying it was deleted and the conflict resolved to feat's `baseline.json`. Restored in the same commit as this ADR. |
