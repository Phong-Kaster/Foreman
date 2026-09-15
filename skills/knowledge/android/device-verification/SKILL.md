---
name: android-device-verification
description: Drive an Android emulator or device so that DoD criteria needing a running app can be machine-checked before a human signs them. Opt-in stack pack.
---

# Driving a device, so a person is not the first to find the bug

## What this is for

A criterion like *"the first time you open the app on a given day, a greeting notification appears"*
cannot be proved by `assembleDebug`. Building is not running. So it gets classed for a human, the run
stops, and the human becomes the tester.

That is expensive in the only currency the loop cannot print. Worse, it is where defects actually
live: on one run fourteen `machine` criteria were green, a fresh-context Verifier re-proved every one
of them, and the human opened the app once and found a feature that had never worked.

This pack does not remove the human. It puts a machine in front of them, so that what reaches them
is what a machine could not break.

## The class it enables

`POLICIES.md` defines three Verification Classes. This pack is what makes the middle one reachable:

| Class | Who drives it | What closes it |
|---|---|---|
| `machine` | a command | the command's output |
| **`machine-then-human`** | **an emulator, `adb`, an instrumented test, an injected clock** | **a person's signature** |
| `human-only` | nothing can drive it | a person's signature |

**A pre-check never closes a criterion.** It fails and becomes a defect, or it passes and the
criterion still goes to the human with the evidence attached.

## Before classifying anything, check what is actually here

Run these. Do not read `knowledge/PROJECT.md` and believe an absence written in it — that is the
failure this pack exists to correct. A repository's notes claimed "no emulator, no device, no `adb`,
no Robolectric, there is no command here that can prove it" while `adb` was installed, a device was
attached, and the project already had a wired `androidTest/` source set. Three runs inherited it.

```bash
adb devices                                    # is anything attached?
ls app/src/androidTest 2>/dev/null              # is the instrumentation source set there?
grep -n 'testInstrumentationRunner\|androidTestImplementation\|managedDevices' app/build.gradle.kts
```

An absence is the one claim that rots silently, because nothing ever fails to remind you of it.

## Prefer a managed emulator over the human's phone

Gradle managed devices declare an emulator in the build file; Gradle creates it, runs the tests on
it, and destroys it.

```kotlin
android {
    testOptions {
        managedDevices {
            localDevices {
                create("pixel6api34") {
                    device = "Pixel 6"; apiLevel = 34; systemImageSource = "aosp-atd"
                }
            }
        }
    }
}
```

```bash
./gradlew :app:pixel6api34DebugAndroidTest
```

Three reasons this beats a physical device, all of them learned the hard way:

- **It starts from a known state.** A criterion that names the state it is driven from (`POLICIES.md`)
  needs that state to be reachable. A connected phone carries whatever the last run left behind.
- **It accepts input.** A real phone may refuse injected events outright — a MIUI device answered
  every `adb shell input` with `SecurityException: INJECT_EVENTS`, so no tap could be performed at
  all, and half the checklist was undriveable.
- **Its data is nobody's.** `pm clear` on an emulator costs nothing. On the human's phone it deletes
  their notes.

## What to check, and how

| Criterion shape | How to drive it | What it still cannot tell you |
|---|---|---|
| A notification appears, with this text, on this channel | `adb shell dumpsys notification` → read `android.title`, `android.text`, `channel=`, `importance=` | whether the icon renders as a flat glyph or a white blob, whether the text is clipped |
| Something happens once per day / survives a restart | an injected `Clock` in a JVM test for the decision; `am force-stop` then relaunch for the persistence | nothing — this one is fully machine-checkable |
| The installed package holds exactly these permissions | `adb shell dumpsys package <pkg>` → `requested permissions:` | nothing |
| The app installs, opens, and does not crash | `adb install -r`, `am start -n`, then `logcat -b crash` | whether the screen it opened is the right one to look at |
| A control is on screen and reachable | UI Automator / Compose test assertions | **whether it can be seen** — contrast, overlap, colour |

That last row is the line. A view-tree assertion says the delete button is present; it said so on the
run where the button shipped rendered invisible against its own background. Screenshot tests catch a
*change* from a recorded baseline, not a bad baseline. Perception stays `human-only`.

## Name the state you drove from, every time

A pre-check that passes is written as **"did not fail when driven from X"**, never "works", and X is
stated.

This is not style. A check of *"fresh install, grant the permission when asked, then open"* was run
on a device where the permission was already granted, reported pass, and the feature was broken on
the path the criterion actually described. Two paths existed; automation took the easy one and
called the criterion proved. Name the starting state or it will happen again.

## Capabilities

`capabilities.snippet.json` in this directory, in three tiers by blast radius. The mechanism worth
understanding: an emulator's adb serial always begins `emulator-` and a physical device's never
does, so `Bash(adb -s emulator-* shell pm clear *)` is a rule the permission matcher can actually
enforce — destructive on a throwaway image, denied on somebody's phone, one pattern.

Tier 3 is withheld deliberately. Read why before you decide you need it.
