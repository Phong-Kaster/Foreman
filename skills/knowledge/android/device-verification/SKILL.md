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
powershell -NoProfile -File .harness/loop/bin/foreman-device.ps1 -Op devices   # is anything attached?
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
- **Its data is nobody's.** The wrapper already confines `pm clear` to the debug build this repository
  produced, but a device is not always yours alone: on 2026-09-30 the shared `astronex_test` emulator
  was being driven by another project's harness at the same time, and every read and tap of this one
  was refused because that app held the screen. A managed device is created for the run and shares
  with nobody.

## What to check, and how

`adb` itself is denied to the engine in both Run Modes (ADR-033). Every device action goes through the
wrapper, `powershell -NoProfile -File .harness/loop/bin/foreman-device.ps1 -Op <operation>`, which acts only on the debug
build this repository produced: it reads that package from the build's own output metadata and checks
that the device reports it installed and `DEBUGGABLE` before touching anything. There is no `-Package`
that reaches another app, and no operation at all for a device setting, the clock or the notification
shade. It echoes every adb command it runs to stderr as `+ adb …`, which is the evidence line to record.

| Criterion shape | How to drive it | What it still cannot tell you |
|---|---|---|
| A notification appears, with this text, on this channel | `-Op notifications` — `dumpsys notification`, filtered to this app's own records: read `android.title`, `android.text`, `channel=`, `importance=` | whether the icon renders as a flat glyph or a white blob, whether the text is clipped |
| Something happens once per day / survives a restart | an injected `Clock` in a JVM test for the decision; `-Op stop` then `-Op start` for the persistence | nothing — this one is fully machine-checkable |
| The installed package holds exactly these permissions | `-Op package-info` → `requested permissions:` | nothing |
| The app installs, opens, and does not crash | `-Op install`, `-Op start`, then `-Op logcat` (crash buffer lines naming the app, and its own log) | whether the screen it opened is the right one to look at |
| A fresh-install or not-yet-granted path | `-Op clear`, `-Op revoke -Permission …`; then `-Op tap -ResourceId …:id/permission_allow_button` on the system dialog the app raised | whether the app's own explanation before the dialog makes sense |
| A control is on screen and reachable | `-Op dump`, then `-Op tap -ResourceId …` / `-Text …` / `-ContentDesc …`, or UI Automator / Compose test assertions | **whether it can be seen** — contrast, overlap, colour — and whether it sits clear of the system gesture zone |
| Playback or another state reached | `-Op media-session` (this app's sessions only) | whether it sounds right |

The wrapper reads and taps only while this app — or the permission dialog it raised — holds the screen.
A tap names its target; raw coordinates are refused, because they cannot be checked against the app
that owns them, and that refusal is also what keeps a tap off the navigation bar. Exit code 3 is a
refusal by the human's rule: do not look for another way to do the same thing.

What this rules out, and how to live with it:

- **Changing animation scales** (`settings put global animator_duration_scale 0`) — a device setting. A
  screen that never goes idle cannot be dumped; pause the animation in the app's debug build, or report
  the criterion not driven.
- **Opening or tapping the notification shade** — it shows every app's notifications. Prove the
  notification with `-Op notifications`; tapping it stays with a person.
- **Reading another app's content provider** (`content query` on the media store) or **pushing files
  into shared storage** — both reach outside the app. Test data belongs in the app's debug build or its
  instrumented tests.
- **Moving the clock** — inject a `Clock` instead.

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

The wrapper needs no grant: `baseline.json` allows it in every repository, and `run.ps1` denies `adb`
in every form the permission matcher was measured to catch (ADR-033). What this pack's
`capabilities.snippet.json` still carries is the instrumented-test route — Gradle managed devices and
`connectedDebugAndroidTest` — for a repository's standing ledger.

The earlier design scoped destructive commands by serial: allowed on `emulator-*`, withheld on a
physical device, with a named-serial exception in
[ADR-031](../../../../docs/adr/ADR-031-a-real-device-is-driven-only-by-a-serial-a-human-named-in-advance.md).
ADR-033 replaces that with a scope by package, which holds on any device: the app under development is
the one thing Foreman may clear, and it may do so wherever that app is installed.
