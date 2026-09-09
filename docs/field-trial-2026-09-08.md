# Field trial — Calendar-Note, 2026-09-08

An end-to-end trial of the Loop Runtime against a real Android codebase, run to observe the harness
rather than to ship a product. Twelve findings came out of it, nine of them already fixed. This
records what was measured, what held up, what did not, and what the two together imply.

**Subject:** `D:\Valve\Calendar-Note` — an existing Jetpack Compose skeleton, 240 tracked files,
Room already wired, Fragment navigation, seven `.claude/*.md` convention documents.
**Requirement:** To-do and Calendar screens with full CRUD, notes scoped to a date, Material 3, blue,
dark mode.
**Engine:** sonnet as Orchestrator and Worker; opus for the analysis fan-out. Observer: opus.

---

## Outcome

| | |
|---|---|
Result | `Status: DONE`, ~75 minutes wall clock |
Delivered | 50 files, +2322 lines, on branch `loop/todo-calendar-screens` |
Tests | 19 passing — **re-verified independently, not taken on trust** |
Build | `assembleDebug` succeeds |
Tasks | 7 of 7, **each on first attempt**, none abandoned, none deferred |
Invocations | 6 (bootstrap, 3 Phases, 1 decision, 1 Verifier) |
Cost | **$22.49** |
Cache hit | **97%** overall |
Escalations | 2, both answered by the supervising session under standing instruction |

Every structural contract held: one atomic checkpoint per Phase, `.harness/run/` removed by the
Cleanup Commit with `ISSUES.md` and `knowledge/` surviving as siblings, the DONE-candidate rule
enforced twice, `main` never touched.

**Honest caveat on the product.** `CoreLayout` paints black unconditionally, so the app is
effectively dark-only: dark mode works, light mode does not really exist. That predates this run.
Full app-wide theme awareness was deliberately recorded as a follow-up rather than attempted, because
its blast radius was invisible to this run's own verification — see D-002 below.

---

## What worked

**Prompt caching is decisive, and now measured on a real repo.** 97% overall hit rate, 91–98% per
invocation. This settles ADR-010's open question: the engine specification is billed at read rates,
so its size is not the thing to optimise. The orientation read is.

**The arm's-length critique earned its cost outright.** Before any code existed it found four real
defects with file-and-line evidence, **two of them holes in the human-written PRD**:

- `dynamicColor` defaults true, so `dynamicLightColorScheme` wins on API 31+ and the blue palette
  would have been silently ignored — an app passing every mechanical gate while looking wrong.
- A Room migration crash that the stated acceptance criteria could not catch, and it said why:
  `exportSchema = false`, no instrumented tests.
- Hidden nodes in the task graph: nothing owned registering entities in `AppDatabase` or binding DAOs,
  so "a worker finishing T-001 cannot demonstrate the behaviour T-001 claims".
- Dark mode dead code (`enableDarkMode` never read) in a file no task owned.

All four landed in the DoD as explicit criteria with an evidence table. This is the strongest single
argument in the trial for ADR-009's converge-after-critique design.

**The Tier-2 boundary held under genuine pressure.** Facing a conflict between its DoD and a
pre-existing defect, the engine traced the root cause exactly, refused the literal fix because it
would have produced invisible dark-on-black text, refused to silently ignore it, named the
out-of-scope files, and escalated with three options — correctly marking the intent change as
human-only. Most striking, it identified a gap in **its own acceptance bar**: the regression it was
warning about "would not be caught by this run's own acceptance bar while still being obviously wrong
to ship".

**Model tiering fired unprompted at bootstrap.** All five analysis roles dispatched at `model='opus'`
with no instruction — the engine read `models.json`, resolved "Capable tier" to an identifier, and
applied the never-downgrade rule. The abstraction held: the spec names tiers, the map supplies names.

**Task decomposition and Phase grouping were sound.** Seven tasks across three Phases, disjoint file
scopes, shared integration files correctly assigned to the Iteration rather than any Worker. Seven of
seven completed first time.

---

## What needs improvement

### Fixed during the trial

| | Finding | Evidence |
|---|---|---|
**F-01** | Runtime did not verify the repo has a commit; a fresh repo failed deep inside bootstrap, far from the cause | Calendar-Note had zero commits |
**F-03** | **Engine could hang forever before starting.** The npm `claude` shim drains `$input` when stdin looks redirected; `run.ps1` redirected stdout but not stdin, so it inherited a pipe that never closes. 11 min alive, 0.3s CPU, zero bytes on stdout *and* stderr, no error | A/B: without fix still hanging at 45s; with fix, exited 5.1s |
**F-05** | ADR-009's five analysis roles had no agent definition, so they ran with an unconstrained toolset while Workers were tightly restricted | Observed `subagent_type='general-purpose'` |
**F-07** | Capability proposals set `lifetime: "goal"` while targeting the *standing* ledger. Nothing cross-checked the two, so a grant calling itself temporary would have become permanent | Both D-001 proposals |
**F-09** | **Tiering was silently inert after bootstrap.** Every Worker and the Reviewer dispatched with `model=None`, inheriting `-Model`. Capable tasks ran below Capable; the Reviewer was downgraded to the builder's own model | `model=None` on 4 of 9 dispatches |
**F-10** | `result` events echo *session-cumulative* cost once per subagent. Summing them overstates spend — and ADR-012 proposes exactly that as an optional cost bound | Naive sum $79.64 vs true $16.95 |
**F-11** | ADR-013 presented "analysis roles always Capable" as purely a quality decision, silent on price | Bootstrap $5.92, of which $4.05 was opus alone — more than the whole Phase 1 build |

### Recorded, not fixed

**F-02 — ADR-013 asserts a property the runtime cannot express.** It says the Orchestrator *and
Verifier* always run at Capable tier, but `run.ps1` has a single `-Model` for every iteration. There
is no way to build cheaply and verify strongly without relaunching the final iteration by hand.

**F-08 — capability rules cannot express a file edit narrower than the whole file.** The engine's
intent was "add one dependency line"; the only rule available is `Edit(app/build.gradle.kts)` — the
entire build file, for the whole goal. Commands express intent precisely; file edits do not.

**F-12 — the DoD can contain a criterion unsatisfiable given pre-existing code, and pre-execution
critique did not catch it.** Criterion 30 could not be met without changing `CoreLayout.kt`, outside
every task's scope. The critique flagged dark mode at bootstrap but neither it nor the DoD-proposal
role noticed the criterion they produced was unreachable. It surfaced only when a Worker's real output
was reviewed. Reading the repo tells you what the code does; only attempting the change reveals which
criteria are *reachable*.

### Not exercised

**The Fast tier never fired.** All seven tasks were classified Capable, correctly — so ADR-013's cost
lever remains unproven in the field, as does the failed-Fast-attempt escalation rule. This is an open
item, not a success.

---

## The cross-cutting lesson

**F-02 and F-09 are the same class of problem: ADRs that are individually sound but were never
checked against each other.** F-02 is ADR-013 asserting something the runtime cannot do. F-09 is
ADR-013 depending on data ADR-010 had removed — ADR-010 shrank the Orient read path for good reasons,
and `models.json` was not in it. Neither ADR is wrong alone. Nothing failed loudly, because every
label survived: task files still said `Model Tier: Capable` while nothing could resolve it.

The repository has no way to verify that the specification's claims are reachable at runtime. That is
the most valuable structural gap this trial exposed, and it is not fixed by any of the nine commits.

**A second pattern, about method.** Six times during this trial the verification step was itself the
thing that was wrong:

- tested `--agents` JSON with a single-line file when the real one is pretty-printed;
- measured cache on a repo whose git state never changed, so the flag under test had nothing to protect;
- ran the suite with a broken shell command, so it silently never executed — masking a real bug the
  test would have caught;
- asserted `ExpectingInput=False` when the property that matters is *finiteness*;
- grepped one file, found nothing, and concluded critique findings were lost when they were in the
  next file;
- summed cost events that echo cumulatively, overstating spend 4.7x and nearly reporting it as fact.

Each looked like diligence. The corrective in every case was checking a *different* observable — a
process tree, an A/B, a second file — rather than looking harder at the first one.

---

## Recommendations

1. **Close the F-02 gap.** Either add a `-VerifierModel` parameter, or let the engine self-select its
   own tier from the Resume Block, or soften ADR-013 to state what the runtime can actually honour.
   Asserting an unenforceable property is worse than admitting the limit.
2. **Exercise the Fast tier deliberately.** Write a PRD containing at least one genuinely trivial,
   mechanically-specified task and confirm both the cheap dispatch and the failure-escalation rule.
3. **Set `-QuotaStopPercent` to 60–70, not 90,** when iterations are expensive. The ceiling guards
   starting an iteration, not finishing one.
4. **Consider a spec-versus-runtime consistency check.** The class of bug behind F-02 and F-09 will
   recur as long as ADRs can assert properties nothing verifies.
5. **Treat the DoD gate as amendable in practice.** F-12 shows criteria can be unreachable through no
   fault of the plan; ADR-001's immutability needs a defined amendment path, which D-002 had to invent.
