# A device is driven only on the debug build Foreman is writing, through one wrapper, in both Run Modes

Autonomous mode compiled every tool as allowed minus a Deny List, and on 2026-09-30 that list was found
to hold no line about `adb` at all. An Autonomous engine was therefore permitted
`adb -s <serial> shell pm clear <any package>` on a person's phone, a `settings put` on any device, and a
tap at any coordinate — the navigation bar, the notification shade, another app. Collaborative mode was
narrower but scoped the wrong thing: `skills/knowledge/android/device-verification`'s snippet allowed
destructive commands on any `emulator-*` serial and withheld them from a physical one
([ADR-030](./ADR-030-a-machine-drives-a-human-criterion-before-a-person-signs-it.md),
[ADR-031](./ADR-031-a-real-device-is-driven-only-by-a-serial-a-human-named-in-advance.md)), which protects
a phone and nothing on the emulator.

The rules were being used to their edges. The Calendar-Note `loop/music-player-v3` Definition of Done
(bootstrap `b5f678a`) drove its criteria with `settings put global animator_duration_scale 0`, a
`content query` on the media store, `cmd statusbar expand-notifications`, and three generated WAV files
pushed into shared storage (assumption A-006). All of it ran on the `astronex_test` emulator, and only
because the Verifier judged the phone "in use by someone else" — a judgement, not a rule.

**Decided by the human, 2026-09-30:** in Autonomous mode Foreman may drive the device and use commands
such as `pm clear`, but only on the debug app it is building; commands aimed at another app or at the
phone's settings are forbidden absolutely. **The same day:** the rule applies to Collaborative mode too.

**What would change this assessment.** A repository whose product *is* a device setting or another app's
integration — a launcher, an accessibility service, a settings panel — for which every criterion would
end "not driven"; or measured runs in which the refusals leave more criteria for a person than the rule
ever prevented harm. Either argues for a per-repository, human-registered exception, never for widening
the wrapper for everyone.

## The mechanism

**`adb` is denied in both Run Modes**, as part of `run.ps1`'s immutable deny rules, so no ledger can
grant it back. **`.harness/loop/bin/foreman-device.ps1` is the only route**, granted in `baseline.json`
for every repository. It runs adb from its own process — where the permission matcher does not reach —
and decides what the device hears:

- **The package is not the engine's choice.** It is the `applicationId` of a debug APK this repository
  built (`<module>/build/outputs/apk/<…debug…>/output-metadata.json`, never the `androidTest` APK), and
  the device must report it installed and `DEBUGGABLE` before anything touches it. A release build or a
  store install under the same id is refused.
- **Every write names that package**: install (only an APK the build produced), uninstall, clear, grant,
  revoke, start, stop.
- **Input goes to a node, not a coordinate.** A tap names a resource-id, text or content description;
  the wrapper takes a fresh view dump, finds the node, and taps its centre only if the node belongs to
  the app or to the system permission dialog it raised. A swipe stays inside one of the app's nodes,
  20% in from its edges. Raw coordinates are refused, and that is also what keeps a tap off the
  navigation bar and the shade.
- **The screen is read only while the app holds it**, and a dump that catches another app's nodes is
  discarded. Shared state — `dumpsys notification`, `dumpsys media_session`, the logs — is filtered to
  the app's own records before it is printed, so another app's notification text never reaches the
  evidence files a checkpoint commits.
- **There is no operation for a setting, the clock, the shade, another app's provider or shared
  storage.** That absence is the rule.

A refusal exits 3, distinct from a device failure (1), and `ENGINE.md` §12 says it is the human's rule,
never a failure to retry.

## The deny rules, measured

The rules were chosen against the real matcher (`claude` 2.1.285, `claude -p --settings`, 2026-09-30),
not by reading. The first candidate, `Bash(*adb *)`, denied all thirteen invocation forms tried — plain,
`.exe`, full POSIX and Windows paths, env prefixes, `cd . &&`, `;`, `bash -c`, `powershell -Command`,
`cmd //c`, a variable, `xargs` — but it would also have denied commits: the engine writes commit
messages inline (`git commit -F - <<'EOF'` and `-m`, 22 commits in the music-player-v3 raw log), and
seven Calendar-Note commit messages mention "adb ". A second set with `Bash(*-c*adb *)` matched
`git -c user.email=…` and denied the wrapper itself.

The shipped set is anchored at the start of a command or at `platform-tools`: 14 of 15 forms denied,
the wrapper allowed, and no false positive on four probes (two commits whose messages quote adb
commands, a `printf` of one, a `grep` for one). The fifteenth, `echo adb | xargs -I{} {} version`, ran:
the matcher splits the pipeline and neither half names adb in a matching position.

The device-automation MCP servers ADR-031 rejected are denied outright as well (`mcp__android-agent`,
`mcp__mobile-mcp`). `android-agent` is installed at user level on the machine these runs use, so every
engine invocation loads it; measured the same day, an ungranted call to it is already refused, and the
explicit rule keeps a ledger from granting it.

## Checked on a real emulator

On `emulator-5554` (`astronex_test`, 2026-09-30), from the Calendar-Note repository: `package`
resolved `com.example.myapplication` from the build output; `install`, `clear`, `start` (the launcher
activity resolved itself), `grant`, `screenshot` and `logcat` worked; `clear -Package
com.android.settings` was refused. Another project's harness was driving the same emulator at the same
time, and when its app, `com.lexiup.aitutor.learnenglish`, took the screen back, a tap, a `HOME` key and
a dump were all refused — the rule meeting the case it exists for, unplanned.

## Considered Options

- **Deny the destructive adb forms and keep `Bash` allowed** — rejected: a deny rule cannot carry an
  exception ("except this package"), and deny wins over allow, so the choice is between blocking the
  app under development and allowing every app.
- **Compile per-package allow rules from the applicationId** (`Bash(adb -s * shell pm clear
  com.example.myapplication)`) — the closest call, since it needs no wrapper for the package-shaped
  commands. Rejected: taps and reads are not package-shaped — `input tap` takes coordinates, and
  `dumpsys notification` prints every app's notifications — so the commands that most need confining
  are the ones a command string cannot confine.
- **Keep scoping by serial** (ADR-030's emulator-only tier, ADR-031's named phone) — rejected: it
  answers "whose device?" while the human's rule is "which app?", and it leaves everything else on an
  emulator — shared, as this ADR's own check found — open to the engine.
- **Allow device settings on an emulator only** — rejected by the human's "absolutely". It is the
  first thing a repository would ask for: a dump cannot be taken of a screen that never goes idle.
- **An MCP driver** — rejected in ADR-031 and denied here.

## Consequences

- Criteria like music-player-v3's no longer drive the way they did: an animated screen must pause its
  own animation in the debug build or be reported not driven; tapping a notification returns to a
  person; test media belongs in the app's debug build or its instrumented tests, not in shared storage.
- The package identity rests on two checks of different strength. The build's output metadata is a
  file the engine can write; the device's `DEBUGGABLE` flag is not. The second is the one that holds.
- ADR-031's named-serial exception is no longer needed for the case it was written for: clearing the
  app under development on a phone is allowed on any device, because the scope is the app. ADR-030's
  serial tiers are gone from the snippet.
- **Not solved:** this is command matching and a wrapper, a guardrail against slips, not a wall. A
  script file that calls adb runs under an allowed `powershell -File`; the `xargs` form above runs; and
  instrumented test code, which Gradle runs with the shell's reach over the device, can do anything the
  wrapper forbids. `ENGINE.md` §14.3's "never route around it" is the only thing against all three.
- **Not solved:** a permission dialog raised by another app looks like one raised by this app; the
  wrapper allows tapping either.
- **Not solved:** another debuggable app on the same device — the human's other projects — is protected
  only by the package having to match this repository's build output, which the engine can edit.
- **Open:** on the Google emulator image the focused dialog package was
  `com.google.android.permissioncontroller`, and a tap on
  `com.android.permissioncontroller:id/permission_allow_button` found no node. Whether the resource-id
  differs on that image or the other harness had changed the screen was not established, because the
  check stopped as soon as the emulator was found to be shared.
