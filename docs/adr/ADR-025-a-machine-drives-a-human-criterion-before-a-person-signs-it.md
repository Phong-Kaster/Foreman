# A machine drives a `human` criterion before a person signs it, and never instead of them

Three runs in one repository ended the same way: all machine evidence green, and a person holding an
unanswered checklist. One left sixteen criteria unsigned, one seven, one six. The second of those is
still unsigned, because a later goal deleted `.harness/run/` and the page built for a human to read
mirrors only the current run's queue — the sixteen questions vanished from the one place anybody
would have seen them.

Then the sharpest piece of evidence arrived. On the third run, fourteen `machine` criteria were
green, a fresh-context Verifier re-proved every one of them from scratch, and a machine check of the
criterion in question reported **pass**. The human opened the app once and found the feature had
never worked: the greeting recorded itself as delivered even when Android had silently dropped it for
want of a permission, so nobody was ever greeted on the day they installed the app.

That machine check was mine, and it is the reason this ADR is cautious. It ran on a device where the
permission was already granted. The criterion said *install fresh, grant when asked, then open*. Two
paths existed; automation took the one that worked and called the criterion proved.

## The absence nobody re-read

`knowledge/PROJECT.md` in that repository stated:

> **No emulator, no device, no `adb`, no Robolectric.** Anything requiring the app to actually run …
> is a `human` verification item, not a machine one. There is no command here that can prove it.

Every run read that at Orient and classified accordingly. It was false. `adb` was installed, a device
was attached, and the project already carried an `androidTest/` source set wired to
`AndroidJUnitRunner` with Espresso and Compose UI test — containing one file, the template's stub.
The engine even built an injected `Clock` seam for the greeting and unit-tested `a new calendar day
greets again`, then classed the next-calendar-day criterion `human` anyway.

Foreman was not missing a mechanism. It was told there was none, and believed the note.

## Decisions

**Three Verification Classes, not two.** `machine` closes on a command. `machine-then-human` is
driven by a machine first and closes on a person's signature. `human-only` is perception — contrast,
readability, whether a control can be seen — and nothing may claim it.

**A pre-check never closes a criterion.** It fails and becomes an ordinary defect, consuming the
task's attempts and abandonable at the third; or it passes, and the criterion still goes to the human
with the evidence attached. The point is to stop the human being the *first* to find a defect, not to
replace them.

**A pass is worded "did not fail when driven from X", and X is stated.** A criterion anything will
drive names the state it is driven from, or automation picks the easy branch — as it did above.

**The pre-check runs at the DONE-candidate gate, once, not every iteration.** Standing up a device
costs minutes and the loop is already the slow part.

**An emulator the build controls is the default; the human's own device is not.** It starts from a
known state, which is what a criterion naming its starting state requires. A physical phone may
refuse automation outright — a MIUI device answered every injected event with `SecurityException:
INJECT_EVENTS`, leaving three of seven checks undriveable — and its data belongs to somebody.

**Capabilities are tiered by blast radius, and the tier is enforceable.** An emulator's adb serial
begins `emulator-`; a physical device's never does. `Bash(adb -s emulator-* shell pm clear *)` is
therefore a rule the permission matcher can enforce by itself: destructive on a throwaway image,
denied on a person's phone, one pattern. The unrestricted form is withheld.

**An unsigned verification request outlives the run that raised it.** Before `.harness/run/` is
deleted — by the Cleanup Commit or by anyone starting a new goal — every criterion still awaiting a
signature moves into `knowledge/ISSUES.md` as a tickable item, not a paragraph mentioning one exists.
The cheapest way to make an inconvenient question disappear must not be "start another run".

**An absence recorded in `PROJECT.md` is re-checked before it is used to classify anything.** One
command settles it. An absence is the only kind of claim that rots silently, because nothing ever
fails to remind you of it.

**The Suggestion Box grows a Verify tab**, one card per criterion awaiting a signature, each leading
with what nobody has looked at and carrying the machine's result underneath as supporting detail. Its
checkboxes are a scratchpad saved per browser; the signature is a `[x]` in `DECISIONS.md`, the file
the Runtime denies the engine write access to. The page is rewritten in full whenever the engine
queues a decision, so a tick in it cannot survive — which is precisely why it must not be the channel.

## Considered options

- **Automate the `human` class away entirely** — rejected, and the evidence is in this ADR. A
  view-tree assertion says the delete button is present; it said so on the run where the button
  shipped rendered invisible against its own background. Converting "unknown" into "verified" is
  strictly worse than leaving it unknown, because it buys confidence it has not earned.
- **Leave the class alone and accept the stops** — rejected: sixteen criteria from one run are still
  unsigned, and a feature nobody has confirmed is not finished. This was the closest call. The cost of
  stopping is visible and large; the cost of a bad pre-check is invisible until it ships.
- **Let the human tick checkboxes in `SUGGESTIONS.html` directly**, as first requested — rejected on
  two grounds, both mechanical. A static page cannot persist a tick to disk, and the engine rewrites
  that file in full on every escalation, so the ticks would be destroyed by the next queued decision.
  The checkboxes stayed, as a scratchpad with a button that emits the markdown to paste.
- **Put `adb` in the baseline ledger** — rejected: device access is repository- and machine-specific,
  and the baseline is what every consumer gets without being asked. It belongs in an opt-in stack
  pack, the same shape as `android/compose-visual-testing`.
- **Have the Runtime drive the device** — rejected: it is an intentionally dumb process (ADR-002).
  The Verifier drives; the Runtime only chose the tier it drives at.

## Consequences

- `ENGINE.md` grew 2,671 bytes and `POLICIES.md` 2,755. **Nothing was retired to pay for it**, and
  under the Ratchet that is a debt: both are injected on every invocation of every run in every
  consumer repository.
- The device checks are opt-in. A repository that pastes no capabilities behaves exactly as before,
  and the honest output in that case is "not driven" per criterion — never a silent skip.

- **Not solved, and measured: a fix iteration triggered by a verification failure runs at Capable.**
  The Runtime picks the model before the process starts, from `STATE.md`'s DONE-candidate flag. On the
  run that fixed the greeting, iteration 41 was ordinary implementation work and cost $13.15 on the
  expensive tier because the flag from iteration 38 was still set when it launched. Teaching the
  Runtime to look ahead at `DECISIONS.md` and guess the iteration's intent is exactly the cleverness
  ADR-002 exists to refuse, so this stands.
- **Not solved: nothing verifies that a pre-check drove the state it claims.** The rule says name the
  starting state; nothing checks the name against what happened. A pre-check that asserts a clean
  install and quietly reuses a warm one would read identically — which is the failure in this ADR,
  written down rather than prevented.
- **Not solved: `human-only` remains a judgement call at bootstrap.** Whether "the greeting is
  readable" is perception or a clipping assertion a screenshot test could pin is decided by the role
  proposing the criterion, and a role that wants fewer stops has an incentive to answer one way.
