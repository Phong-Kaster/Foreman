# Field trial — Kanso, Run 8, 2026-10-14

Kanso's eighth run, observed from start to finish by a supervising session. Its goal was to make the
app's five photo-editing tools really edit the photo, using the image engine already compiled into the
repository. It was the first run on ADR-040's read guard, and it ran into the iteration-budget bug that
PR #14 then fixed. The run ended `DONE_PARTIAL` with every machine check green. Driving the app by hand
afterwards found a broken feature that the run had reported as built. This records what was measured,
what held up, what did not, and the lessons nothing else in the repository records yet.

**Subject:** `D:\Valve\Personal\Kanso`: Jetpack Compose, Navigation 3, Koin, an engine of prebuilt AARs
(OpenCV, LiteRT, MediaPipe, ML Kit) imported from Retica. 574 tests at the start.
**Requirement:** Edit, Remove background, Enhance, Retouch and Artistic edit the photo, offline. Save
writes the edited result. Every behaviour change updates the README.
**Engine:** Autonomous mode. Sonnet ran Workers and most Iterations; Opus was the Verifier.
**Devices:** the owner's Galaxy A13 (`armeabi-v7a`), and an emulator `hcm146_api34` (API 34, `x86_64`)
started by the supervising session.

---

## Outcome

| | |
|---|---|
Result | `Status: DONE_PARTIAL`, iteration 10 of 50, 12:37–15:39 |
Delivered | All five tools edit the photo; 8 tasks in 5 Phases on `loop/kanso-editing-tools` (Kanso PR #6) |
Tests | 574 → 690, 0 failed; Roborazzi pictures 41 → 51 (7 re-recorded, 10 new), all green |
Cost | **10 iterations, 2 h 39 min of engine time, 23.2 M cache-read tokens, $32.35** ($30.39 Sonnet, $1.95 Opus) |
Escalations | 1, the DoD approval (D-001). Answered in the supervising session. |
Left for a person | 17 screenshot pictures (recorded later by hand), four device criteria (7, 9, 11, 13) never driven, eight human-judgement items |

Run 7, before ADR-040, took 17 iterations and $104. The work and the model mix were different, so this
is a data point, not a measurement of the guard.

---

## What worked

- **Autonomous mode ran without a person**, apart from the DoD gate, a quota stop and an account
  switch. Each Phase ended in one checkpoint, and the Verifier ran twice.
- **The README rule bit.** The owner's new `CLAUDE.md` rule says a behaviour change updates the README
  in the same commit. The Verifier found the README still describing the app before the edits, filed
  T-008, and the next Iteration fixed it. A rule written into the consumer's own conventions was
  enforced by the engine without any Foreman doctrine behind it.
- **The quota path held.** At 14:36 both Workers of Phase 3 stopped on the five-hour limit. The
  Iteration reverted their unverified partial work and committed a note saying Phase 3 needed a retry.
  The Runtime then logged `Quota ceiling: five_hour at 100%` and slept with the remaining time named
  (`03:31:30`). After a relaunch, Phase 3 was redone cleanly.
- **ADR-040's knowledge split held.** Kanso's `PROJECT.md` went from 72 KB to 30 KB, with 15 topic files
  under `knowledge/reference/`. The read guard refused two calls in the whole run (see ADR-040, Field
  results), against Run 7's 24 whole-file reads of `DoD.md` and `PROJECT.md` in five iterations.
- **The record wrapper did exactly what ADR-036 says**, once someone called it. It kept the seven
  re-recordings listed under `## Baselines`, added the ten new pictures, and put nothing else back.

---

## What needs improvement

### Fixed during the trial

1. **A new run inherited an earlier run's commits as its own iterations.** Run 8 opened at
   `Iteration 26 / 50`, because Run 7's branch was not merged and `Get-PriorIterationCount` counted
   `main..HEAD`. The count now starts at the run's own bootstrap. Fixed in PR #14; the relaunched run
   logged `resuming at iteration 3 - 2 already checkpointed`.
2. **Kanso: two pictures could not be recorded**, because the screenshot test scrolled to a button in a
   panel that does not scroll. Fixed in Kanso `6956f78`.
3. **Kanso: Artistic ignored the chosen style.** Fixed in Kanso `325f0f2`; see lesson 4 below, which is
   about why the run did not catch it.

### Recorded, not fixed

These are written here so they are not lost. None has been turned into doctrine yet. Each names the
failure that would earn its line under the Ratchet.

**1. The engine ran the denied record command three times and never the wrapper.**
At 14:21, 15:04 and 15:30 an Iteration ran `./gradlew :app:recordRoborazziDebug --tests '*ToolScreenshotTest*'`.
That command is denied in both Run Modes. Each time the Iteration wrote "recording the baselines is
denied", carried 17 pictures into `ISSUES.md` for a person, and moved on. `capabilities/baseline.json`
grants `foreman-record-baselines.ps1`, `packs/android/roborazzi.md` names it, and D-001 had approved
the exact list. The run ended `DONE_PARTIAL` on that alone. The supervising session then ran the
wrapper and had all 17 recorded, judged and committed within minutes. A refusal of the raw record task
does not point to the wrapper, so nothing in the denial helped the engine find the allowed path.

**2. The device criteria were never driven, though an emulator had been started for them.**
The Verifier checked devices only through `foreman-device.ps1 -Op focus`, at 15:10 and 15:25. Both
times the wrapper's `adb devices` listed one device, the A13, whose focus was another app. The Verifier
wrote "the Galaxy A13 was in use, no emulator was running" and ended the run. `emulator-5554` had been
booted from the supervising session at about 15:20, and the session's own `adb devices` listed it then.
Why the wrapper did not see it at 15:25 is **not known**: it may not have finished coming online, or it
may have been gone already. Nobody retried, and nothing in the run asked for an emulator to be started.
The four device criteria (7, 9, 11, 13) are the only ones that run the native engine, and they were
skipped. Driven by hand on the emulator afterwards, they took about 15 minutes and found lesson 4.

**3. "In use" is judged by focus, and the A13's focus was never Kanso.**
Across the day the A13's foreground app was `com.languagelearning.app`, then LexiUp, then the language
app again. Every check from the engine and from the supervising session read that as "a person is using
the phone", and so Run 8 never touched the phone. Focus cannot tell a person holding the phone from an
app left open on a phone lying on a desk. ADR-033's rule ("never take a screen that is somebody else's")
is right; what is missing is a way to ask, and an answer that can be "it's free".

**4. A tool that the run reported as built did not work, and nothing on the computer could have seen it.**
`EngineStylizer` passed the style-transfer engine `FULL_STYLE_RATIO = 1f`. Its own KDoc said this was
unverified: "1 might instead mean 'all original'". It did mean that. Every Artistic style produced the
photo's own style, so Warm wash, Mosaic and Ink were pixel-identical: a mean difference of 0 over the photo,
against 33 between any of them and the original after Undo. Still, 690 tests passed, the Reviewer passed the Phase, and the Verifier re-proved
every machine criterion. No test runs an `Engine*` wrapper, because the engine is native and cannot load
on the host JVM. The only criterion that could catch it was a device criterion, and those were the ones
skipped (lesson 2). With `0f`, the value Retica uses, the styles differ (mean difference 261).
`DONE_PARTIAL` said "every machine check holds"; it did not say that one of the five tools had never
been seen to work.

**5. The read guard disagrees with ADR-040 in two places, and the archive step never ran.**
Recorded in full in ADR-040's **Field results** section. In short: a bootstrap analyst was refused
`.harness` itself, a Worker was refused a file its own task owned under `run/evidence/`, and Kanso's
`ISSUES.md` reached 65 KB with Runs 3–7 still inside it.

**6. A sleeping run cannot notice a new login.**
After the quota stop, the owner logged in with a second account. The Runtime was 3 h 31 min into a
wait it would only end at the old account's reset. Using the new account meant killing the sleeping
process and relaunching. That was safe, because no engine was running, but it was a manual step,
taken only because someone was watching.

### Not exercised

- The Galaxy A13: nothing from Run 8 has run on the owner's phone.
- A Collaborative-mode run on this runtime.
- ADR-040's migration of a `PROJECT.md` that still holds Reference: Kanso's had already been moved in Run 7.

---

## The cross-cutting lesson

**`DONE_PARTIAL` with every machine check green can still hide a feature that does not work, when the
unchecked criteria are exactly the ones that exercise the risky code.** Run 8's machine checks proved
the Kotlin around the engine: crop maths, mask blending, size caps, failure paths, Save. They could not
prove the engine calls themselves, and the DoD said so by giving those to devices. Lessons 1 and 2
are the same shape: an allowed path existed (the record wrapper, the emulator), and the run reported the
blocked one as the reason it stopped. Lesson 4 is what that cost: a broken tool that every report called
built.

The engine's own code had flagged the risk. A constant marked "unverified" in a KDoc, whose only
proving criterion is a device criterion that was not driven, is an unproven claim. Nothing carried it
from the code comment into the Run Report.

---

## Recommendations

Not doctrine yet. Each one is earned by the failure named, and each waits for a decision.

1. **A denied command should name the allowed one.** Where `baseline.json` grants a wrapper for a task
   the raw command is denied for, the denial or the stack pack should say which wrapper (lesson 1).
2. **A device criterion "not driven" should say what was tried.** That means which devices were
   listed, and whether an emulator could have been started. Starting one is a capability question for
   the human, not something to assume (lessons 2 and 3).
3. **Ask, do not infer, whether a device is free.** A line in `DECISIONS.md` or the DoD naming the
   device the run may use, or a standing grant, would replace a focus guess that never says yes
   (lesson 3).
4. **The Verifier lists what the code itself calls unverified.** Grep the run's diff for "unverified"
   and similar markers, and name each in the Run Report beside the criterion that would prove it
   (lesson 4).
5. **Fix the guard's two gaps and find out why the archive step did not run**, as ADR-040's Field
   results section says (lesson 5).
6. **Let a quota wait end early when a new login is present**, or at least tell the person that a
   relaunch is safe while it sleeps (lesson 6).
