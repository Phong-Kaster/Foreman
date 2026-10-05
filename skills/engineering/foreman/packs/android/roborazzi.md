# Roborazzi - Foreman's default UI check for Android apps

Ships with the runtime, so every repository Foreman is installed in has it (ADR-036). Read it at
Bootstrap when the repository is an Android app, and whenever you write or run a screenshot test.

## What it gives you

[Roborazzi](https://github.com/takahirom/roborazzi) captures an app's real screens **on the JVM, with
no device**: [Robolectric](https://github.com/robolectric/robolectric) runs the app's own Activity,
fragments, navigation, ViewModels and DI, a Compose test taps and waits, and `captureRoboImage` saves
the screen. Against an approved image, `verifyRoborazzi<Variant>` fails on any change and writes
`build/outputs/roborazzi/<name>_compare.png`: reference, diff and new, side by side. Open that image -
the diff marks the element that changed, which is where the fix goes.

It runs in every iteration's test command, not only at the Verifier gate, and it needs none of what
broke device checks on real runs: no phone in use by someone else, no emulator shared with another
harness, no locked screen, no input refused by the vendor, no dump that cannot go idle under an
endless marquee.

## What it cannot tell you

Robolectric draws **no system bars**: no status bar, no navigation bar, no gesture area. A control in
the gesture zone, the notification shade, the system permission dialog and the lock screen are not
real here. Those criteria stay `machine-then-human`, driven on a device and signed by a person.

## Setup (verified 2026-10-05 on AGP 9.0.1, Kotlin 2.2.10, Gradle 9.1.0, JDK 24)

`gradle/libs.versions.toml`:

```toml
[versions]
roborazzi = "1.76.0"
robolectric = "4.17"
androidxTestCore = "1.7.0"

[libraries]
roborazzi = { group = "io.github.takahirom.roborazzi", name = "roborazzi", version.ref = "roborazzi" }
roborazzi-compose = { group = "io.github.takahirom.roborazzi", name = "roborazzi-compose", version.ref = "roborazzi" }
robolectric = { group = "org.robolectric", name = "robolectric", version.ref = "robolectric" }
androidx-test-core = { group = "androidx.test", name = "core", version.ref = "androidxTestCore" }

[plugins]
roborazzi = { id = "io.github.takahirom.roborazzi", version.ref = "roborazzi" }
```

Root `build.gradle.kts`: `alias(libs.plugins.roborazzi) apply false`. App `build.gradle.kts`: apply
`alias(libs.plugins.roborazzi)`, add `testOptions { unitTests { isIncludeAndroidResources = true } }`,
and `testImplementation` for `roborazzi`, `roborazzi-compose`, `robolectric`, `androidx.test.ext:junit`,
`androidx-test-core`, the Compose BOM and `ui-test-junit4`. All test-only: nothing ships in the APK.

The first run downloads Robolectric's Android jars and took 192 s; later runs took 15-28 s.

## Writing a test

One test per flow a criterion names, driven to the state the criterion names:

```kotlin
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
class LibraryFlowScreenshotTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Before fun setUp() {
        shadowOf(ApplicationProvider.getApplicationContext<Application>())
            .grantPermissions(Manifest.permission.READ_MEDIA_AUDIO)
        loadKoinModules(module { single<MusicRepository> { FakeMusicRepository(songs) } })
    }
    @After fun tearDown() = stopKoin()

    @Test fun tap_a_song_shows_the_mini_player() {
        ActivityScenario.launch(MainActivity::class.java).use {
            compose.waitUntil(10_000) { compose.onAllNodesWithText("City Rain").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("City Rain").performClick()
            compose.waitForIdle()
            compose.onRoot().captureRoboImage("src/test/screenshots/2_library_playing.png")
        }
    }
}
```

- **Fake only the boundaries that need a phone** - the media store, the player, the network. Keep the
  Activity, navigation, ViewModels and DI real, or the screenshot proves a test double.
- **A fake must suspend the way the real one does.** A fake that returned without suspending left the
  Library spinner up forever, because the ViewModel recorded its loading job only after `launch`
  returned. That was a real latent defect, and worth reporting - but a fake that hides or invents
  timing is not evidence of anything.
- **Wait for content, not for idle.** Data loads in coroutines; `waitUntil` on a node the state must show.
- **Stop the DI container after each test.** The application starts Koin (or Hilt) per Robolectric
  run, and the global context outlives it.
- **Baselines live in `<module>/src/test/screenshots/`**, named `<n>_<state>.png`, and are committed.

## Baselines are the exam; you never move them

- **New** baselines are recorded only through
  `powershell -NoProfile -File .harness/loop/bin/foreman-record-baselines.ps1 -Module app`. It records,
  then puts back every baseline that already existed, so only images that did not exist are added.
  Open each new image and judge it against the criterion and POLICIES.md's User-Interface Defects
  before you commit it: that look is the judgement the baseline will defend from then on.
- **Re-recording an existing baseline is the human's decision.** Queue it (Tier 2, naming the files);
  the human approves by listing them under a `## Baselines` heading in `.harness/run/DECISIONS.md`.
  The wrapper then keeps the new version of exactly those files.
- **Every other route is denied**, in both Run Modes: `recordRoborazzi*`, `verifyAndRecordRoborazzi*`,
  `clearRoborazzi*`, and `roborazzi.test.record` on any Gradle command. The Runtime also checks the
  commits after every iteration: an existing baseline changed without being listed under
  `## Baselines` stops the run (`FAILED`), whatever route changed it - `gradle.properties` included.
- Prove with `verifyRoborazzi<Variant>`; `compareRoborazzi<Variant>` writes the diff without failing.
