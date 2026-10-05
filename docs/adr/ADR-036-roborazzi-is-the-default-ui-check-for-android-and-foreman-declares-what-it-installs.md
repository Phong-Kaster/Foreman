# Roborazzi is the default UI check for Android, and Foreman declares what it installs, for itself and for the consumer

Foreman had two ways to prove an Android screen worked, and both fell short. Compose Preview Screenshot
Testing (`skills/knowledge/android/compose-visual-testing`) renders `@Preview` composables on the host,
which shows a screen standing still and never a screen after a tap. The device route
(`foreman-device.ps1`, ADR-033) drives the real app, but only at the Verifier gate, because standing a
device up is slow, and it broke on real runs in six different ways:

- a Xiaomi refused injected taps;
- a vivo asked for confirmation on every install;
- the vivo was locked or its screen was off;
- adb dropped to `offline`;
- the phone was "in use by someone else", so Calendar-Note `loop/music-player-v3` drove 12 screen
  criteria on an emulator instead (A-006);
- on 2026-09-30 the emulator was shared with another project's harness.

**Decided by the human, 2026-10-05**, after the spike below: if Roborazzi held up, Foreman uses it by
default whenever it builds an Android app. The same day, two more decisions: README and the guide gain
a section naming every library and repository Foreman uses, why, and where it comes from. And wherever
Foreman is installed it takes the steps to install what it needs, with Foreman's own tools kept apart
from what goes into the consumer repository.

**What would change this assessment.** A stack Roborazzi cannot render (a Robolectric release lagging
the platform, as Paparazzi historically lagged AGP), or measured runs in which baselines catch nothing
the device and the person would not have caught anyway. Either sends the default back to opt-in.

## The spike

The spike ran on Foreman-Proving-Ground, the Calendar-Note repository renamed, on branch
`spike/roborazzi` cut from `loop/music-player-v3`. Its setup was Roborazzi 1.76.0, Robolectric 4.17
(`sdk = 35`), AGP 9.0.1, Kotlin 2.2.10, Gradle 9.1.0 and JDK 24. It used one test, with the app's own
`MainActivity`, fragments, navigation, ViewModels and Koin, and fakes only for the media store and the
player.

- **Real screens after interaction, with no device.** It captured three screens: the library, then
  the library after a tap with the mini player showing, then Now Playing after a tap on the mini player.
  The first run took 192 s while Robolectric's jars downloaded; later runs took 15-28 s. The titles'
  endless `basicMarquee` rendered fine, although that kind of animation is what made device dumps fail.
- **It catches a defect, and points at it.** The spike drew the mini player's artist line in
  `surfaceVariant`, so it was invisible against its bar, the same class of defect as the invisible
  delete button of ADR-015. `verifyRoborazziDebug` failed in 21 s. Its `_compare.png` showed reference,
  diff and new side by side, with the diff marking exactly that line. With the colour put back, verify
  was green in 17 s.
- **It found a latent bug nobody planted.** A fake repository that returned without suspending left
  the Library spinner up forever, because `LibraryViewModel` assigns `loadSongsJob` only after `launch`
  returns. The real repository always suspends onto IO, so no user sees this today, but the first cache
  that returns at once would expose it.
- **It showed the hole to close.** With the defect in place, `testDebugUnitTest
  -Proborazzi.test.record=true` exited 0 and rewrote one baseline. `verifyRoborazziDebug` then passed,
  defect and all.
- **It showed what it cannot see.** Robolectric draws no system bars, so the mini-player gesture-zone
  defect of v3 would still pass.

## The decision

**Roborazzi is the Android default, and its knowledge ships with the runtime:**
`.harness/loop/packs/android/roborazzi.md`, a new distributable directory, so every install has it
without opting in. At Bootstrap, ENGINE.md §5 reads `dependencies.json`'s `consumer` entries for the
stack. In an Android app, adding the default entries is the first task of the first Phase, without asking.

**Decided by the human later the same day:** Roborazzi, Robolectric, AndroidX Test and Compose UI Test
are Foreman's standing toolchain, not an approval item at the DoD gate. They are test-only and never
ship in the app, and the engine records them in `PROJECT.md`. Only a `PRD.md` or `DOMAIN.md` that
forbids new dependencies overrides this. An entry that is not `default` (Compose Preview Screenshot
Testing) is proposed in the DoD like any other change. Every screen a criterion
names gets a test that drives it to the named state. The engine judges the first image itself and
commits it as the baseline. `verifyRoborazzi<Variant>` joins every iteration's test commands, and a
failure's `_compare.png` is read before anything is changed (§6.7).

**Baselines are out of the engine's reach, by three mechanisms:**

1. **Deny rules in both modes.** Measured against the real matcher: `*gradlew*recordRoborazzi*`,
   `*gradlew*RecordRoborazzi*` (which `verifyAndRecord` needs), `*gradlew*clearRoborazzi*` and
   `*gradlew*roborazzi.test.record*` denied all six record forms tried, including `cd . &&` and a quoted
   property. Verify, compare, the wrapper, and a commit message naming `recordRoborazziDebug` all ran.
2. **New baselines through `bin/foreman-record-baselines.ps1`.** It records, then puts back every
   baseline that existed.
3. **A guard in `run.ps1` that checks the files themselves after every iteration.** It works whatever
   route moved them, `gradle.properties` included. An existing baseline whose bytes changed stops the
   run with `FAILED`, unless the human listed it under `## Baselines` in `DECISIONS.md`, the file the
   engine cannot write. That listing is also how the wrapper knows a re-record was approved.

**What Foreman installs is declared in one file, `.harness/loop/dependencies.json`, in two groups that
never mix:**

- `foreman` lists tools on the machine Foreman runs from: Claude Code, Git, Windows PowerShell 5.1,
  Node.js, the skills CLI, the Context7 CLI, adb, and Pester for developing Foreman itself. The skill's
  new step 0c runs each `check` before every launch. It lets npx fetch what it can (`auto`), shows the
  install command and asks before anything else, stops only on a missing required tool, and never
  installs system software unasked.
- `consumer` lists, by stack, what the engine adds to the consumer's own build: Roborazzi, Robolectric,
  AndroidX Test, Compose UI Test, and the opt-in Compose Preview Screenshot Testing. These are
  test-only, with versions. The `default` ones are added without asking, and the skill never
  installs any of them.

README's "What Foreman depends on" and the guide's matching section show both tables, and a test keeps
all three in step.

## Considered Options

- **Maestro** (15.9k stars) - rejected as the default. It needs a device, so five of the six device
  failures above remain. It is slow enough that it suits the Verifier gate rather than every iteration.
  And it reaches the device through its own driver, past ADR-033's wrapper. It stays the candidate for a
  better device-side tool. This was the closest call.
- **Paparazzi** (2.6k stars) - rejected: it renders a composable or view standing still, the same reach
  as the Compose Preview tool Foreman already has, and its 2.x line was still alpha.
- **Appium** (22k stars) - rejected: it is a general automation server, still needs a device, has no
  built-in baseline comparison, and can drive any app.
- **Compose Preview Screenshot Testing as the default** - rejected: previews cannot show a screen
  after a tap. It stays as an opt-in pack.
- **Roborazzi's AI image assertion** - not used: it sends screenshots to Gemini or OpenAI with an API
  key, and another model's verdict is not evidence (ADR-031).
- **Guard the baselines by denying edits to `gradle.properties`** - rejected: Gradle writes the images
  itself, not through the engine's Edit tool, and a repository legitimately edits that file. Checking
  the files catches every route at once.
- **Guard by diffing the iteration's commits** - rejected: it misses a baseline changed and left
  uncommitted, and a crash leaves exactly that.
- **One file for the skill to read and a separate list in README** - rejected: two lists drift, and
  `guide-parity.md` exists because they do.

## Consequences

- Android criteria about what a screen shows after an interaction are proved on the host in every
  iteration. The device and the person are left with what only they can see: system UI, the gesture
  zone and perception.
- A consumer repository's build gains test-only dependencies at Bootstrap, without being asked. The
  human sees them in the first Phase's commit and in `PROJECT.md`, not at the gate.
- **Not solved:** the only way to turn the default off is to forbid new dependencies in `PRD.md` or
  `DOMAIN.md`. There is no switch for "everything but Roborazzi".
- **Found while doing this:** `docs/index.html` never gained the `FOREMAN.html` line README's tree got
  in ADR-034's commit. That is the drift `guide-parity.md` warns about, and it is fixed here.
- **Not solved:** a deleted baseline does not stop the run; it is logged. Deleting a screen under the
  DoD's Removals legitimately deletes its baseline, and the guard cannot tell the two apart.
- **Not solved:** the first image of every baseline is the engine's judgement of a picture. It becomes
  evidence only once pinned (POLICIES.md), and nothing checks the first look.
- **Not solved:** the versions in `dependencies.json` were verified on one stack, on one day. Nothing
  re-checks them as Roborazzi and Robolectric move on.
- **Open:** the spike's latent `LibraryViewModel` defect is reported here but not fixed. It belongs to
  the consumer repository.
