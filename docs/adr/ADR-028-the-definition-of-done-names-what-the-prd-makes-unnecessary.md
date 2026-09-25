# The Definition of Done names what the PRD makes unnecessary, and the human approves the removals at the gate

The first Autonomous run (Calendar-Note, `loop/music-player`, 2026-09-24) built a working music player
on a repository its own bootstrap summary called a "pristine skeleton" — one commit, `initial: Android
Compose skeleton with Room, Fragment navigation, core layer`. It added 2,888 lines and removed 59. What
it left behind, traced by reachability from the music feature's real entry points (`MainActivity`,
`MainApplication`, the `MusicPlaybackService` the manifest declares, and `MusicFragment`, the start
destination): **61 of the 99 Kotlin files, about 3,445 of 6,691 lines, unreachable** — the skeleton's
Home screen and its posts demo, the Setting and language screens, `PostApi`, `WeatherApi`, Room with two
DAOs, Ktor, a rating bottom sheet with its Lottie animations, and eleven extension files nothing calls.
The manifest still declared `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `SCHEDULE_EXACT_ALARM`,
`INTERNET` and `ACCESS_NETWORK_STATE` for an offline music player. The human's verdict on reading the
branch: these should have been deleted.

Four things pushed the run the same way, and none of them was a reasoning failure:

1. **The question was framed without the answer in it.** Assumption A-002 weighed "Music beside Home"
   against "rewrite Home into Music". Neither option was "the skeleton's features are demonstrations;
   remove the ones the PRD does not use", although the engine had already recognised the skeleton.
2. **"Additive and reversible" was taken as a reason.** A-002 kept everything because the option was
   "additive and reversible". On the Loop Branch a deletion is exactly as reversible — one `git revert`.
3. **The spec had no word for code the PRD makes unnecessary.** `ENGINE.md` §13 said "Never: modify
   unrelated files", and nothing distinguished unrelated code from code the requirement has made
   useless. Everything already there read as unrelated.
4. **Every DoD criterion asserted presence.** All fifteen said "X exists / works". None said "Y is
   gone", so the Verifier, re-proving the DoD, had nothing that could fail on a dead screen.

Autonomous mode sharpened it. In Collaborative mode A-002 would have been a question, and the human
would have answered it.

## The decision

Four changes, each placed where one of the causes lived.

**The DoD carries a Removals section** (`ENGINE.md` §5, `templates/DoD.template.md`). Bootstrap
inventories what the repository already ships that the PRD makes unnecessary — screens and navigation
entries, permissions, services, dependencies, demo data — and proposes each removal as a `machine`
criterion stating absence, provable by command. The human approves removals at the gate they always
see, alongside everything else; after approval, leaving one in place is a DoD violation the Verifier
can catch. An empty section must say why. Whether existing code stays is therefore intent, owned by
the human, and never an Assumption (`ENGINE.md` §14.1): a keep-or-remove question discovered after
approval is Tier 3.

**Bootstrap classifies the repository** as a *template* — a scaffold whose features are
demonstrations — or a *product*, and records the class and its evidence in `PROJECT.md`. In a template
it proposes removing every demo feature the PRD does not use. In a product it proposes removing only
what the PRD replaces or leaves unreachable, and lists anything else that merely looks unused as a
question, not a removal.

**§13 separates unrelated code from unnecessary code**, and says outright that "additive" is not a
reason to keep code, because deletion on the Loop Branch is exactly as reversible as addition.

**Dead code is a review finding** (`POLICIES.md` Review Standards, `agents/loop-reviewer.md`): anything
nothing reachable uses after the diff is at least Major, Critical when the Removals names it, and must
be shown by command — the manifest, the dependency list, the navigation graph, a search with no caller.
An unused permission is called out as a user-visible defect, not tidiness.

## Considered Options

- **Let the engine delete whatever it judges unused, without asking** — rejected. Deleting a feature is
  a statement about intent, and intent is the human's (Invariant 1). An engine that decides alone which
  of a product's features are still wanted would be as wrong as one that never deletes, in the other
  direction, and harder to notice.
- **A "prune" phase at the end of every run, removing whatever lint reports unused** — rejected as the
  primary mechanism. Unused-code analysis finds unreferenced symbols, not screens that are still wired
  into navigation but no longer wanted; the Calendar-Note Home screen was fully reachable from the tab
  bar. It survives as part of the reviewer's evidence, not as the decision.
- **Only the reviewer change** — rejected: the reviewer judges a diff against the DoD, and a DoD that
  never mentions removal gives it nothing to hold the diff to. It catches leftovers the Removals missed;
  it cannot decide what should go.
- **Remove only in template repositories** — this was the closest call. It is the safest reading, and
  the Calendar-Note failure was a template. It was rejected because a product PRD that replaces a
  feature ("switch the list to a grid") leaves the old one just as dead; the product rule is narrower —
  what the PRD replaces or leaves unreachable, with everything else asked as a question — rather than
  absent.

## Consequences

- The DoD approval now also approves deletions, so the gate reads longer. That is the intended cost:
  it is the one moment a human looks, and a removal list is quicker to read than a branch.
- `ENGINE.md` grows from 37,419 to 39,581 bytes and `POLICIES.md` from 27,978 to 28,754. Nothing was
  retired to pay for it. Every added line cites the Calendar-Note run.
- A Tier-3 question now exists in Autonomous mode — a keep-or-remove question found after approval —
  and §14.1 already resolves Tier 3 toward the PRD's literal text and marks criteria assumed, so it
  cannot stall a run.
- **Not solved:** the template/product classification is a judgement from signals (one initial commit,
  "skeleton" in names, placeholder content). A real product that happens to have one squashed commit
  and a package named `skeleton` would be misclassified, and the proposed Removals would be too
  aggressive. The human sees the class and the list at the gate, which is the only defence.
- **Not solved:** nothing yet proves the change works on a real run. The spec tests pin that the four
  requirements are present, not that an engine obeys them. The next template run is the evidence.
- **Open:** the Calendar-Note branch itself still carries the dead code. Removing it is a new run's
  job, or a human's, not this ADR's.
