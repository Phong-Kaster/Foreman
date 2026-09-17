# A real device is driven only by a serial a human named in advance; a second agent's self-report is never evidence

`skills/knowledge/android/device-verification`'s Tier 3 withholds every unrestricted-serial
destructive command, because nothing about a bare `adb -s <serial>` tells the permission matcher
whether it is about to wipe a scratch image or a person's phone
([ADR-025](./ADR-025-a-machine-drives-a-human-criterion-before-a-person-signs-it.md)). That
withholding is correct and stays; but it leaves every criterion that genuinely needs a physical
device paying a full live Escalation Request, every time, in every run — exactly the cost the
Calendar-Note field trial measured directly (two escalations inside a 75-minute run,
`docs/field-trial-2026-09-08.md`), and exactly the shape of ADR-025's own incident, where a human was
the first person to discover a "notification appears" criterion had never actually worked.

This ADR closes the gap for the one case that does not need a live question at all: a human already
owns a device they intend to sacrifice to testing, and says so in advance. It also settles, from a
review that worked through three off-the-shelf mobile-automation libraries as candidate drivers, that
none of them belongs in the path that produces evidence.

## Part 1 — a named serial is a capability, registered in advance, not a question asked mid-run

A human may register a specific device serial into a capability ledger before a run begins, the same
way any other capability enters the trust chain (`Human → Capability Ledger → Runtime Compiler →
Permission Settings → Engine`, [ADR-004](./ADR-004-capability-permission-and-trust-chain.md)):

```
Bash(adb -s <exact-serial> shell pm clear *)
Bash(adb -s <exact-serial> shell pm revoke *)
Bash(adb -s <exact-serial> shell pm grant *)
Bash(adb -s <exact-serial> shell settings put *)
Bash(adb -s <exact-serial> shell date *)
```

identical in shape and scope to the emulator-only Tier 2 already in `capabilities.snippet.json` —
app-level state only, never a device-wide wipe. Bootstrap reads the ledger; a registered serial is
used, an absent one falls back to an emulator exactly as today, silently. Nothing pauses to ask.

**Registration happens once, out of band, never mid-run.** The trust chain forbids the engine
expanding its own scope (ADR-004: "the human decides... never the engine expanding it"), and a live
"may I use this device?" mid-iteration is a new escalation, not a saved one — it pays the exact
wall-clock cost this ADR exists to remove.

**The grant is goal-scoped, not standing.** An emulator cannot silently change what it is; a real
device can — repurposed, lent out, handed a personal account — with nothing in the repository to
notice. Re-confirming the grant per goal keeps that drift bounded to one run, the same reasoning
ADR-025 already gives for Tier 2 on emulators.

**Factory reset is not "clean state," and is never granted.** Wiping a real Android device typically
revokes its own USB-debugging authorization, which only a human tapping the device screen can
restore — reintroducing, mechanically, the exact wait this ADR removes. "Clean" here means the app's
own data and permissions, already inside Tier 2's existing shape; never the device's.

## Part 2 — the driver stays `adb`/`uiautomator`; a second agent's opinion is not evidence

Three off-the-shelf libraries were reviewed as candidate drivers: `mobile-mcp`, `android-agent`
("Ghost in the Droid"), and `mobile-use`. None replaces `adb` in the path that produces evidence, for
two separate reasons that apply to different subsets of them.

**`mobile-mcp` is the wrong shape, not the wrong idea.** Its tools are atomic and deterministic —
closer in spirit to `uiautomator` than to an autonomous agent — but they arrive as MCP tool calls, not
literal Bash strings, so the capability ledger's matcher has nothing to pin a serial to; and it runs
as a server that must be kept alive, which does not fit a Runtime that treats every iteration as a
fresh process ([ADR-002](./ADR-002-stateless-iteration-dumb-runtime.md)). It also answers a need —
iOS — nothing in this project has yet had: no PRD, no run, no evidence the mismatch is worth taking on.

**`android-agent` and `mobile-use` are the wrong idea, for the criteria that matter.** Both hand a
natural-language goal to an autonomous agent and receive a natural-language report back. Tested
directly against this project's own incident — a notification/permission criterion, the same shape
ADR-025's false pass came from — the failure reproduces exactly: nothing stops the second agent from
quietly driving the easy path (permission already granted) and reporting the hard path (fresh
install, grant when prompted) as proven, and Foreman has no way to tell, because it never receives a
command's output — only prose. That prose is not `machine` evidence (no command ran that Foreman can
point at) and not `machine-then-human` (no person signed it); it is a fourth, ungoverned class ADR-025
never admitted, and admitting it now would reopen the exact failure that ADR wrote down.

`android-agent` does carry two components that do not carry this risk, because neither asks Foreman to
trust a live judgment:

- its BFS App Explorer, a structured crawl with no natural-language goal to misinterpret, run by a
  human as an out-of-band advisory pass — never invoked by the engine, never gating an iteration;
- its Skill Creator, a development-time aid a human uses once to draft `adb`/`uiautomator` glue code,
  reviewed like any other patch and, once accepted, run directly — at which point the library is no
  longer a runtime dependency at all.

`mobile-use` has neither: no deterministic replay, no non-agentic exploration mode, nothing that is
not the live natural-language agent. It is not adopted in any capacity.

## Considered Options

- **Detect any device with USB debugging enabled and drive it automatically** — rejected: this is
  Tier 3's withheld wildcard restated in different words. Most Android developers leave debugging on
  permanently on their own daily phone; the property proves nothing about disposability.
- **Detect `ro.build.type = userdebug/eng` and self-grant** — rejected as a self-grant, though it is a
  materially better signal than USB debugging alone. A rare daily-driver on an engineering image still
  exists, and regardless of accuracy, the engine expanding its own permission scope is what ADR-004
  forbids outright. It may still be surfaced inside a Bootstrap Escalation as a suggestion for the
  human to register — never as a grant the engine gives itself.
- **Ask live, the first time a run needs a real device** — rejected: reopens the wall-clock cost under
  investigation, and would be the one capability in the system driven by live Q&A while every other
  one is a pre-registered ledger entry.
- **Permit full factory reset as the reset-to-clean mechanism** — rejected: invalidates USB-debugging
  authorization, which only a human at the device can restore.
- **Grant the named serial as a standing capability** — rejected as the default: a real device's role
  can drift silently in a way an emulator's category cannot; goal-scoping forces re-confirmation.
- **Drive through `mobile-mcp`** — rejected: its tool calls are not the Bash-argv strings the ledger
  enforces, and its server model does not fit the stateless Runtime; also unearned today, since no
  project here has needed iOS.
- **Let an autonomous agent (`android-agent`'s live mode, or `mobile-use`) act as, or feed, the
  Verifier's pre-check** — rejected, and this was the closest call of this review, precisely because
  the scenario proposed and tested against real evidence — routing a permission/notification criterion
  through such an agent — reproduces ADR-025's own incident exactly, with the failure now hidden
  behind a second opaque agent instead of visible in Foreman's own pre-check.
- **Treat `android-agent`'s natural-language report as `machine-then-human` evidence, attached for a
  human to read alongside their own check** — rejected as evidence, though its screen recording and
  live-stream features remain legitimate *conveniences for the human doing the signing* — the
  distinction is that a recording only helps a person verify faster, it never substitutes for them
  looking.

## Consequences

- Tier 3's unrestricted-serial form stays withheld exactly as ADR-025 wrote it. This ADR adds a
  named-serial form beside it, not a replacement, scoped identically to the existing emulator-only
  Tier 2.
- A repository with no registered real-device serial behaves exactly as it does today — silent
  fallback to an emulator, per ADR-025's "not driven... never a silent skip." No new escalation path
  is introduced by this decision.
- `android-agent`'s BFS explorer and Skill Creator gain a named, narrow place to be used — outside the
  evidence path, never invoked by the engine mid-run — rather than being an unwritten judgment call
  for whoever next considers the library.
- **Not solved:** nothing mechanically verifies a registered serial is still a dedicated test device
  by the time a later run uses it. A phone registered today can become somebody's daily device next
  month with the ledger entry never revisited; this ADR narrows Tier 3, it does not add an expiry or a
  liveness check for that drift.
- **Not solved:** an `adb` serial is not a permanently stable identifier the way the `emulator-`
  prefix's OS-level category is; a rare device-side event could regenerate it and silently orphan a
  ledger entry.
- **Not solved:** nothing stops a human from manually pasting an `android-agent` finding into a DoD
  criterion as though it were machine-derived. The boundary Part 2 draws is enforced by this document,
  not by the permission matcher, unlike the serial-pinning mechanism in Part 1.
- **Open:** none of the three libraries reviewed here has been run against a real Foreman goal. This
  ADR is a design review, not a field trial; the capability entries in Part 1 have not yet been added
  to `capabilities.snippet.json`, and Part 2's advisory uses have not yet been tried on a real run.

**Decided by the human, 2026-09-18**, after a review that worked through the alternatives above in
sequence rather than from a single incident; the incidents it cites (the notification-permission false
pass, the Calendar-Note escalation count) are real and already recorded in ADR-025 and the field
trial, reused here rather than re-measured.

_What would change this: a field run that actually exercises the named-serial grant and finds the
goal-scoping too disruptive to be worth it; or a future version of `mobile-use` or `android-agent`
that grows a deterministic, non-agentic replay mode comparable to Skills, which would put it back in
Part 2's "consider it" column instead of "not adopted."_
