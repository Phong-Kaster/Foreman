---
name: android-compose-visual-testing
description: Make visual acceptance criteria provable on an Android Compose repo before a Foreman run starts — host-side Compose Preview Screenshot Testing, the exact verified setup, the capability entries to grant (and the one to withhold), and the gotchas that cost real debugging. Load when a PRD asks for anything about appearance, contrast, layout or what a user can perceive, and `gradlew test` cannot prove it.
disable-model-invocation: true
---

# Android Compose visual testing — a Foreman stack pack

A **stack pack** in the sense of [ADR-019](../../../../docs/adr/ADR-019-knowledge-stratification-and-ratchet.md): platform knowledge that does not belong in `.loop/` (Foreman never knows the consumer's tech stack) and does not belong in a repo's `knowledge/` (it is not truth about *that* repository). Opt-in, human-curated, versioned separately. It lives under `skills/knowledge/android/` — one subfolder per platform — because a stack pack that does not name its platform is fine with one platform installed and noise the moment a second one is.

Install it in a repo **before** starting a run, not after. Everything below was verified end-to-end on a real repo; nothing here is from documentation alone.

---

## Why this exists

Foreman requires every DoD criterion to be provable by evidence — command plus observed output. A PRD that says *"a date that has notes is visually distinguishable from a date that has none"* states a real requirement that `gradlew test` cannot prove: a unit test can assert the date is in the model, not that the marker is visible.

Left unsolved, that produces one of two outcomes, and both have happened:

1. The engine escalates at bootstrap — a hard stop before any code is written.
2. Worse, the criterion gets narrowed to its machine-checkable part. The narrow version passes, the fresh-context reviewer has no standard to judge appearance against, and the run reports a verified `DONE` over a requirement that is untrue. A dot drawn in `primary` on top of a `primary`-filled circle shipped exactly this way — invisible on the one day a user looks at first.

With this installed, visual criteria go into the DoD as ordinary provable criteria and neither outcome occurs.

---

## Why this tool and not Paparazzi or Roborazzi

It is the natively supported path, and it renders with layoutlib **on the JVM** — no emulator, no connected device. That matters because "no criterion may depend on an emulator" is a constraint real PRDs impose, and because Paparazzi historically lags AGP releases.

Verified working on: **AGP 9.0.1, Kotlin 2.2.10, Gradle 9.1.0, JDK 24, Compose BOM 2024.09.00.**
Requirements: AGP 9.0+, Kotlin 2.2.10, JDK 17+.

---

## Setup

**1. Version catalog** — `gradle/libs.versions.toml`

```toml
[versions]
screenshot = "0.0.1-alpha15"

[libraries]
screenshot-validation-api = { group = "com.android.tools.screenshot", name = "screenshot-validation-api", version.ref = "screenshot" }

[plugins]
screenshot = { id = "com.android.compose.screenshot", version.ref = "screenshot" }
```

**2. `gradle.properties`**

```properties
android.experimental.enableScreenshotTest=true
```

**3. Module `build.gradle.kts`**

```kotlin
plugins {
    alias(libs.plugins.screenshot)
}

android {
    experimentalProperties["android.experimental.enableScreenshotTest"] = true
}

dependencies {
    screenshotTestImplementation(libs.screenshot.validation.api)
    screenshotTestImplementation(libs.androidx.compose.ui.tooling)
}
```

**4. Paths**

| | |
|---|---|
| Test sources | `app/src/screenshotTest/kotlin/<package>/` |
| Reference images | `app/src/screenshotTestDebug/reference/<package>/<FileKt>/` |

**5. Confirm before writing tests** — `gradlew.bat :app:tasks --all` should list `updateDebugScreenshotTest` and `validateDebugScreenshotTest`. If it does not, the plugin did not apply and no test will tell you so.

**6. Workflow**

```
gradlew.bat updateDebugScreenshotTest     # record references
gradlew.bat validateDebugScreenshotTest   # verify against them
```

---

## Capabilities: grant `validate`, withhold `update`

Add to the repo's standing ledger (`knowledge/capabilities.json`) — the snippet is in `capabilities.snippet.json` beside this file:

```
Bash(*validateDebugScreenshotTest*)     ← grant
Bash(*updateDebugScreenshotTest*)       ← do NOT grant
```

**This asymmetry is the most important line in this pack.** `update` overwrites the reference images. An engine holding it, facing a failing screenshot test, has a one-command route to making the failure disappear by re-recording the wrong output as correct. That is the same class of act as editing the Definition of Done, and Foreman's whole trust chain exists because a rule a script enforces is a rule while a rule in a prompt is a wish (ADR-002).

So: the engine may **check** against the baseline, never **move** it. When a UI change is intentional and the baseline must move, that is either a human act or a one-time goal-scoped capability the human grants at an escalation — the same pattern the Cleanup Commit already uses.

---

## Write the previews through the app's real theme

A preview that renders a component bare is worthless as evidence. Studio's preview pane defaults to a white background and Material's baseline colours, which is exactly how a screen full of hardcoded `Color.White` looks correct in the pane and unreadable in the app — or the reverse, if the app paints a dark ground.

Wrap every case in the app's own theme, over the app's own background:

```kotlin
@Composable
fun ScreenshotScaffold(content: @Composable () -> Unit) {
    YourAppTheme {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(MaterialTheme.colorScheme.background)
                .padding(12.dp),
        ) { content() }
    }
}
```

Then:

```kotlin
@PreviewTest                                  // required — without it the preview is not executed
@Preview(name = "…", widthDp = 360, heightDp = 120)
@Composable
private fun SomeCase() { ScreenshotScaffold { YourComponent(...) } }
```

Imports: `com.android.tools.screenshot.PreviewTest`, `androidx.compose.ui.tooling.preview.Preview`.

---

## What to cover, and how to know it works

Cover **combined states**, not each state alone. The overlaps are where the defects live: selected *and* flagged, today *and* has-content, done *and* long-titled. A marker that repeats the colour of the shape it sits on is invisible only in the overlap, and every isolated case passes.

Then **prove the suite can fail.** Reintroduce a defect you have already fixed, run `validateDebugScreenshotTest`, confirm it goes red and names the cases you expected, and restore. A screenshot suite that has never failed is decoration, and it is cheap to be sure rather than hopeful.

---

## Gotchas that cost real debugging

- **`@PreviewTest` is mandatory.** A `@Preview` without it is silently not executed — no test, no error.
- **A lazy vertical scroller inside a `verticalScroll` throws at measure time** ("infinity maximum height"). Fixed `heightDp` in a preview exposes layout assumptions the app hides. For a month grid or any short fixed list, plain `Column`/`Row` is both correct and cheaper than `LazyVerticalGrid`.
- **Reference images are tracked binaries.** An intentional UI change requires re-recording and committing them, or the suite goes red for the right reason at the wrong time. Say so in the repo's `knowledge/PROJECT.md` so the next run is not surprised.
- **Baseline only the screens a run touches.** On a large app, recording everything is a large binary diff nobody reviews.
- **The suite is memory-hungry** — it renders on the JVM. Raise the test JVM heap in `gradle.properties` if it struggles.

---

## What transfers and what does not

| Transfers between repos | Stays per-repo |
|---|---|
| Plugin choice and version, the Gradle wiring, the `ScreenshotScaffold` pattern, the `validate`/`update` capability asymmetry, every gotcha above | The reference images, and which screens are worth covering |

That split is the point of a pack. The harness cannot be downloaded — it is shaped by one repo's failure history — but the recipe can.
