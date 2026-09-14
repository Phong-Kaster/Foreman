# The commit log is the cross-branch index; the subject line is written to be searched

`knowledge/` was designed to survive every feature run, and the README promises that build commands and environment quirks are "paid for once, not once per feature". That promise holds along **one branch lineage only**, and nothing said so.

`knowledge/` lives on the Loop Branch. The engine never merges (ADR-003, and it is an invariant, not a default). So a second run started from the default branch — the ordinary thing to do when the first run is finished but not yet merged — begins with no access to anything the first run learned.

**The observed failure** (Phong-Kaster/Calendar-Note, 2026-09-10). A prior run on `loop/todo-calendar-screens` had built, debugged and verified a complete host-side Compose screenshot-testing harness: the version-catalogue entries, the Gradle plugin, a reusable scaffold, and fifteen committed reference images, on an alpha-versioned plugin that had cost that run its own escalation and several iterations to get right. A second run branched from `main`. Its bootstrap escalation stated:

> **Not possible today**: this repository has no Robolectric and no host-side test setup.

and proposed adopting a different framework. The engine held `Bash(git show*)` the entire time. It had no reason to look.

## Why the obvious fix is the wrong one

The first fix considered was: at bootstrap, enumerate `loop/*` branches and check each tip for a `knowledge/` directory that `HEAD` lacks.

That would not have worked. **The screenshot harness was never in `knowledge/`.** It was in `gradle/libs.versions.toml` and `app/src/screenshotTest/` — ordinary project files. A scan targeting the knowledge directory would have reported nothing and confirmed the engine's conclusion.

The generalisation matters more than the example: what a prior run leaves behind is not confined to any directory. It can be a build-file entry, a test source set, a tooling script, a gradle property, a workaround in a config file. Any file-location-based search has to guess where reusable work lands, and will be wrong whenever it guesses narrowly.

## What actually survives, and is already indexed

One thing about a prior run is guaranteed to survive, span every branch, and cost one command to read: **its commit messages.**

```
$ git log --all --oneline --format="%s"
loop(T-010): host-side screenshot harness imported, six references recorded
...
test(calendar): pin visual behaviour with host-side screenshot tests      <- the answer
fix(theme): fill every colour role and drop the unusable light scheme
```

Run against the repository at the moment of the failure, that command surfaces the missed work on line fifteen, from the branch that was never merged, in one invocation, using a capability already in the baseline ledger. No checkout, no branch walking, no guessing at directories.

`.ai/` is deleted at the Cleanup Commit. `knowledge/` may never be merged. The log is the only durable, cross-branch, human-readable index the system already maintains — and until now nothing read it and nothing was written for it to be read.

## The decision

**1. Bootstrap reads the log before concluding anything is missing** (`ENGINE.md` §5, new step 3). `git log --all --oneline` plus `git log --all --grep="^Reusable:"`. If prior work is found that this run would otherwise re-derive, the engine may neither silently adopt it nor silently ignore it: it names it in the Bootstrap Escalation Request as an explicit option — *"a prior run on `<branch>` already solved X; import it, or re-derive it?"* Adopting another run's architecture is a Tier-2 decision, so it belongs to the human, and bootstrap is already stopping for approval anyway. The marginal cost is two commands and a few lines in an escalation that is written regardless.

**2. The commit subject is written to be searched** (`POLICIES.md` § Git Conduct). An index is only as good as its wording, so the convention now carries three requirements:

- **Scope** is the task id, or one of `bootstrap`, `decision`, `knowledge`, `infra`, `complete`. `knowledge` when the point of the commit is what the repository now knows; `infra` when it lands reusable tooling, test harness or build configuration.
- **Name the artefact, not the activity.** `loop(infra): add host-side Compose screenshot testing (no emulator)` is findable by a future run searching for a way to prove visual criteria. `loop(T-010): wire up testing` is not.
- **A `Reusable:` trailer** in the body of any commit leaving something a future run could adopt, naming the capability and where it lives. This turns `git log --all --grep="^Reusable:"` into an exact query rather than a read-through of every subject ever written — which matters on the second long-lived repository, not the first.

The two halves are not independent. The read step without the writing convention degrades as history grows; the writing convention without the read step indexes something nobody opens.

## Considered Options

- **Scan `loop/*` branch tips for `knowledge/`** — rejected on the evidence above: it would have missed the actual artefact, because reusable work is not confined to a directory. It also costs a branch walk where a log read costs one command.
- **Commit `knowledge/` to the default branch** — rejected: the engine must never touch the default branch (ADR-003), and making an exception for one directory would put the engine's own writes on the branch the human merges into, which is the boundary the whole design defends.
- **Auto-import whatever a prior branch holds** — rejected: adopting another run's architecture is Tier 2 by `POLICIES.md`'s own classification, and a prior run's solution may have been abandoned precisely because it was wrong. The engine surfaces it; the human decides.
- **A machine-readable manifest — `knowledge/REUSABLE.json`, written at the Cleanup Commit** — rejected, and this was the closest call. It would be precise and queryable without any convention about prose. But it is a fifth artifact with a fifth lifecycle, it lives in `knowledge/` and therefore inherits exactly the unmerged-branch problem being solved, and it would be maintained in parallel with commit messages that already carry the same information. The `Reusable:` trailer gets the queryability into the artifact that already survives.
- **Search the log at Orient, every iteration** — rejected: the expensive re-derivation happens at bootstrap, before any code exists. By iteration two the architecture is chosen and a per-iteration scan re-answers a question that cannot change, in a file read every iteration, which is the cost `STATE.md` compaction exists to avoid.

## Consequences

- Commit messages acquire a second audience. They were written for a human auditing a finished run; they are now also read by a machine starting a new one. The convention shifts accordingly — toward naming the durable artefact rather than the day's activity.
- The **scope vocabulary is now fixed and small**, where it was previously free-form. `loop(phase-2)` from an older run is still legible but no longer conforming.
- **A `Reusable:` trailer is a claim the engine makes about the future**, which nothing verifies. A trailer on something that turns out not to be reusable costs a future run one escalation option it will reject. That asymmetry is acceptable — the cost of a false positive is a question, the cost of a false negative is re-deriving an alpha-versioned Gradle plugin from scratch.
- **Not solved:** nothing corrects a prior run's `knowledge/PROJECT.md` once it is stale. The Calendar-Note repository currently holds a lesson about `set -o pipefail` being unavailable, which ADR-022 made untrue, on an unmerged branch, with no mechanism to notice. This ADR makes prior work *findable*; it does not make it *trustworthy*, and a future run adopting an old lesson has no way to know its age beyond the commit date.
- **Not solved:** the same reasoning applies to the engine's own portable lessons, which still have no home outside one repository's `knowledge/PROJECT.md` (ADR-019's deferred `CANDIDATES.md`). A `Reusable:` trailer makes such a lesson findable across branches of the same repository. It still does not travel between repositories.
